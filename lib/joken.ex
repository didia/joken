defmodule Joken do
  @moduledoc """
  Joken is a library for generating, signing, validating and verifying JWT tokens.

  ## Architecture

  The core of Joken is `JOSE` library which provides all facilities to sign and verify tokens.
  Joken is a simpler Elixir API that provides a few facilities:

    - Validating claims. You can set up functions for validating custom claims in a portable way.
    - `config.exs` friendly. Define your signer configuration straight in your `config.exs` (even 
    for pem encoded keys or open ssh keys). This might help having different keys for development
    and production. 
    - Portable configuration. You can simply `use Joken.Config` in a module and it will give you
    default generate and verify functions. This encapsulates better your token code.
    - Enhanced errors. Joken strives to be as informative as it can when errors happen be it at 
    compilation or at validation time.
    - Debug friendly. When a token fails validation, a `Logger` debug message will show which claim 
    failed validation with which value. The return value, though for security reasons, does not 
    contain these information.
    - Performance. We have a benchmark suite for identifying where we can have a better performance. 
    From this analysis came: Jason adapter for JOSE, redefinition of :base64url module and other 
    minor tweaks. 

  ## Usage

  Joken has 2 concepts:

    - A token claim configuration
    - A signer configuration

  The claim configuration is a map of binary keys to `Joken.Claim` structs and is used to dynamically
  generate and validate tokens.

  A signer is an instance of `Joken.Signer` that encapsulates the algorithm used to sign and verify a
  token.

  Please, refer to `Joken.Config` for more details on usage of both concepts. Here is a simple example:

      defmodule MyAuth do
        use Joken.Config, default_signer: :pem_rs256
      
        @impl true
        def token_config do
          default_claims()
          |> add_claim("role", fn -> "USER" end, &(&1 in ["ADMIN", "USER"]))
        end
      end
      
      token = MyAuth.generate_and_sign(%{"user_id" => "1234567890"})
      {:ok, _claim_map} = MyAuth.verify_and_validate(token)
  """
  alias Joken.{Signer, Claim}
  require Logger

  @current_time_adapter Application.get_env(:joken, :current_time_adapter, Joken.CurrentTime.OS)

  @doc """
  Retrieves current time in seconds. 

  This implementation uses an adapter so that you can replace it on your tests. The adapter is
  set through `config.exs`. Example:

      config :joken, 
        current_time_adapter: Joken.CurrentTime.OS

  See Joken's own tests for an example of how to override this with a customizable time mock.
  """
  def current_time, do: @current_time_adapter.current_time()

  @doc """
  Decodes the header of a token without validation.

  **Use this with care!** This DOES NOT validate the token signature and therefore the token might 
  be invalid. The common use case for this function is when you need info to decide on which signer 
  will be used. Even though there is a use case for this, be extra careful to handle data without 
  validation.
  """
  def peek_header(token) when is_binary(token) do
    %JOSE.JWS{alg: {_, alg}, fields: fields} = JOSE.JWT.peek_protected(token)
    Map.put(fields, "alg", Atom.to_string(alg))
  end

  @doc """
  Decodes the claim set of a token without validation.

  **Use this with care!** This DOES NOT validate the token signature and therefore the token might 
  be invalid. The common use case for this function is when you need info to decide on which signer 
  will be used. Even though there is a use case for this, be extra careful to handle data without 
  validation.
  """
  def peek_claims(token) when is_binary(token) do
    %JOSE.JWT{fields: fields} = JOSE.JWT.peek_payload(token)
    fields
  end

  def generate_jti do
    binary = <<
      System.system_time(:nanoseconds)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      :erlang.unique_integer()::32
    >>

    Base.hex_encode32(binary, case: :lower)
  end

  def verify(bearer_token, signer, hooks \\ [])

  def verify(bearer_token, signer, hooks) when is_binary(bearer_token) and is_atom(signer),
    do: verify(bearer_token, parse_signer(signer), hooks)

  def verify(bearer_token, signer = %Signer{}, hooks) when is_binary(bearer_token) do
    with {:ok, bearer_token, signer} <- before_verify(bearer_token, signer, hooks),
         claim_map <- Signer.verify(bearer_token, signer),
         {:ok, claim_map} = after_verify(bearer_token, claim_map, signer, hooks) do
      {:ok, claim_map}
    end
  end

  def validate(token_config, claims_map, context, hooks \\ []) do
    with {:ok, claims_map, config} <- before_validate(claims_map, token_config, hooks),
         result <- reduce_validations(token_config, claims_map, context),
         result <- parse_validate_result(result, claims_map),
         {:ok, result} <- after_validate(result, claims_map, config, hooks) do
      result
    else
      {:error, key, claim_val} ->
        {:error, message: "Invalid token", claim: key, claim_val: claim_val}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_validate_result(result, claim_map) do
    case result do
      :ok ->
        {:ok, claim_map}

      {:error, key, claim_val} ->
        {:error, message: "Invalid token", claim: key, claim_val: claim_val}
    end
  end

  def generate_claims(token_config, extra_claims, hooks \\ []) do
    with {:ok, extra_claims, token_config} <- before_generate(extra_claims, token_config, hooks),
         claims <- Enum.reduce(token_config, extra_claims, &Claim.__generate_claim__/2),
         {:ok, claims} <- after_generate(claims, hooks) do
      {:ok, claims}
    end
  end

  def encode_and_sign(claims, signer, hooks \\ [])

  def encode_and_sign(claims, signer, hooks) when is_atom(signer),
    do: encode_and_sign(claims, parse_signer(signer), hooks)

  def encode_and_sign(claims, signer = %Signer{}, hooks) do
    with {:ok, claims, signer} <- before_sign(claims, signer, hooks),
         token <- Signer.sign(claims, signer),
         {:ok, token} <- after_sign(token, claims, signer, hooks) do
      {:ok, token, claims}
    end
  end

  defp parse_signer(signer_key) do
    signer = Signer.parse_config(signer_key)

    if is_nil(signer),
      do: raise(Joken.Error, :no_default_signer),
      else: signer
  end

  defp reduce_validations(config, claim_map, context) do
    Enum.reduce_while(claim_map, nil, fn {key, claim_val}, _acc ->
      # When there is a function for validating the token
      with %Claim{validate: val_func} when not is_nil(val_func) <- config[key],
           true <- val_func.(claim_val, context) do
        {:cont, :ok}
      else
        # When there is no configuration for the claim
        nil ->
          {:cont, :ok}

        # When there is a configuration but no validation function
        %Claim{validate: nil} ->
          {:cont, :ok}

        # When it fails validation
        false ->
          Logger.debug(fn ->
            """
            Claim %{"#{key}" => #{inspect(claim_val)}} did not pass validation.

            Current time: #{inspect(Joken.current_time())}
            """
          end)

          {:halt, {:error, key, claim_val}}
      end
    end)
  end

  defp before_verify(bearer_token, signer, hooks),
    do: run(hooks, :before_verify, [bearer_token, signer])

  defp before_validate(claims_map, token_config, hooks),
    do: run(hooks, :before_validate, [claims_map, token_config])

  defp before_generate(extra_claims, token_config, hooks),
    do: run(hooks, :before_generate, [extra_claims, token_config])

  defp before_sign(claims, signer, hooks),
    do: run(hooks, :before_sign, [claims, signer])

  defp after_verify(bearer_token, claims_map, signer, hooks) do
    with {:ok, _bearer_token, claims_map, _signer} <-
           run(hooks, :after_verify, [bearer_token, claims_map, signer]) do
      {:ok, claims_map}
    end
  end

  defp after_validate(result, claims_map, config, hooks) do
    with {:ok, result, _claims_map, _config} <-
           run(hooks, :after_validate, [result, claims_map, config]) do
      {:ok, result}
    end
  end

  defp after_generate(claims, hooks),
    do: run(hooks, :after_generate, [claims])

  defp after_sign(token, claims, signer, hooks) do
    with {:ok, token, _claims, _signer} <- run(hooks, :after_sign, [token, claims, signer]) do
      {:ok, token}
    end
  end

  defp run(hooks, fun, args) do
    result =
      Enum.reduce_while(
        hooks,
        {:ok, args},
        fn hook, {:ok, args} ->
          case apply(hook, fun, args) do
            {:ok, arg} ->
              {:cont, {:ok, [arg]}}

            {:ok, arg1, arg2} ->
              {:cont, {:ok, [arg1, arg2]}}

            {:ok, arg1, arg2, arg3} ->
              {:cont, {:ok, [arg1, arg2, arg3]}}

            {:error, reason} ->
              {:halt, {:error, reason}}

            _ ->
              {:halt, {:error, :wrong_callback_return}}
          end
        end
      )

    with {:ok, args} <- result do
      List.to_tuple([:ok | args])
    end
  end
end
