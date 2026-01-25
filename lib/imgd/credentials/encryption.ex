defmodule Imgd.Credentials.Encryption do
  @moduledoc """
  AES-256-GCM encryption/decryption for credential data.

  Credentials are encrypted at rest using AES-256-GCM with a per-credential
  random IV. The master key is derived from the application configuration.

  ## Security Notes

  - Each credential gets a unique 12-byte IV
  - 16-byte authentication tag ensures data integrity
  - AAD (Additional Authenticated Data) version is included to allow future migrations
  """

  @aad "imgd_credentials_v1"
  @iv_bytes 12
  @tag_bytes 16

  @doc """
  Encrypts a map of credential data.

  Returns the encrypted binary in format: IV (12 bytes) || ciphertext || tag (16 bytes)
  """
  @spec encrypt(map()) :: {:ok, binary()} | {:error, term()}
  def encrypt(data) when is_map(data) do
    try do
      key = get_encryption_key!()
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      plaintext = Jason.encode!(data)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          plaintext,
          @aad,
          @tag_bytes,
          true
        )

      {:ok, iv <> ciphertext <> tag}
    rescue
      e -> {:error, {:encryption_failed, Exception.message(e)}}
    end
  end

  @doc """
  Decrypts an encrypted credential blob back to a map.

  Expects binary in format: IV (12 bytes) || ciphertext || tag (16 bytes)
  """
  @spec decrypt(binary()) :: {:ok, map()} | {:error, term()}
  def decrypt(encrypted) when is_binary(encrypted) do
    try do
      key = get_encryption_key!()

      # Extract IV, ciphertext, and tag
      <<iv::binary-size(@iv_bytes), rest::binary>> = encrypted
      ciphertext_size = byte_size(rest) - @tag_bytes
      <<ciphertext::binary-size(ciphertext_size), tag::binary-size(@tag_bytes)>> = rest

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) ->
          {:ok, Jason.decode!(plaintext)}

        :error ->
          {:error, :decryption_failed}
      end
    rescue
      MatchError -> {:error, :invalid_encrypted_format}
      e -> {:error, {:decryption_failed, Exception.message(e)}}
    end
  end

  @doc """
  Returns the encryption key from application config.

  The key must be exactly 32 bytes (256 bits) for AES-256.
  In config, use: `config :imgd, :credential_encryption_key, "base64_encoded_32_byte_key"`
  """
  def get_encryption_key! do
    case Application.get_env(:imgd, :credential_encryption_key) do
      nil ->
        raise """
        Credential encryption key not configured!

        Generate a key with: :crypto.strong_rand_bytes(32) |> Base.encode64()

        Then set in config/runtime.exs:
        config :imgd, :credential_encryption_key, System.fetch_env!("CREDENTIAL_ENCRYPTION_KEY")
        """

      key when is_binary(key) ->
        case Base.decode64(key) do
          {:ok, decoded} when byte_size(decoded) == 32 ->
            decoded

          {:ok, decoded} ->
            raise "Credential encryption key must be 32 bytes, got #{byte_size(decoded)}"

          :error ->
            raise "Credential encryption key must be base64 encoded"
        end
    end
  end

  @doc """
  Generates a new encryption key for initial setup.
  Returns a base64-encoded 32-byte key.
  """
  def generate_key do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end
end
