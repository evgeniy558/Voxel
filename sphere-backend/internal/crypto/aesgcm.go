package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
)

func NewGCMFromHexKey(keyHex string) (cipher.AEAD, error) {
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("encryption key must be 64 hex chars (32 bytes)")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func EncryptString(gcm cipher.AEAD, plaintext string) (ciphertext, nonce []byte, err error) {
	n := make([]byte, gcm.NonceSize())
	if _, err = io.ReadFull(rand.Reader, n); err != nil {
		return nil, nil, err
	}
	ct := gcm.Seal(nil, n, []byte(plaintext), nil)
	return ct, n, nil
}

func DecryptToString(gcm cipher.AEAD, ciphertext, nonce []byte) (string, error) {
	pt, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", err
	}
	return string(pt), nil
}

