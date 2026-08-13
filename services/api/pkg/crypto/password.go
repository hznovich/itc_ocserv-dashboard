package crypto

import (
	"golang.org/x/crypto/bcrypt"
)

// CustomPassword keeps the original two-field shape (Salt + Hash) so the rest of
// the codebase (DB schema, repository, controllers) does not need to change.
//
// With bcrypt:
//   - Salt is random and embedded in the hash by bcrypt itself, so we always
//     return Salt = "" and store the full bcrypt hash in Hash.
//   - The CheckPassword function ignores the legacy `salt` argument.
//
// Existing rows still using the old MD5 scheme are detected by hash length
// (32 hex chars) and rejected — those users need a password reset, which is
// the safer behaviour after a hash-algorithm migration.
type CustomPassword struct {
	Salt string
	Hash string
}

type CustomPasswordInterface interface {
	CreatePassword(passwd string, saltLength ...int) CustomPassword
	CheckPassword(passwd, hashedPassword, salt string) bool
}

// bcryptCost = 12 is a reasonable default in 2026: noticeably slower than 10
// (the bcrypt library default) without being painful on a typical VPS.
const bcryptCost = 12

func NewCustomPassword() *CustomPassword {
	return &CustomPassword{}
}

func (c *CustomPassword) CreatePassword(passwd string, _ ...int) CustomPassword {
	hash, err := bcrypt.GenerateFromPassword([]byte(passwd), bcryptCost)
	if err != nil {
		// GenerateFromPassword only fails on absurd inputs (>72 bytes) or
		// invalid cost. Returning an empty hash forces a guaranteed compare
		// failure later instead of silently weakening auth.
		return CustomPassword{}
	}
	return CustomPassword{
		Salt: "",
		Hash: string(hash),
	}
}

func (c *CustomPassword) CheckPassword(passwd, hashedPassword, _ string) bool {
	if hashedPassword == "" {
		return false
	}
	// Legacy MD5 hex hashes are exactly 32 chars and contain no '$' marker.
	// bcrypt hashes always start with "$2a$", "$2b$" or "$2y$".
	if len(hashedPassword) == 32 && hashedPassword[0] != '$' {
		return false
	}
	err := bcrypt.CompareHashAndPassword([]byte(hashedPassword), []byte(passwd))
	return err == nil
}
