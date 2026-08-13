package crypto

import (
	"strings"
	"testing"
)

func TestCreatePassword_ProducesBcryptHash(t *testing.T) {
	p := NewCustomPassword()
	out := p.CreatePassword("hunter2")

	if out.Hash == "" {
		t.Fatal("expected non-empty hash")
	}
	if !strings.HasPrefix(out.Hash, "$2a$") && !strings.HasPrefix(out.Hash, "$2b$") {
		t.Fatalf("expected bcrypt hash prefix, got: %q", out.Hash)
	}
	if out.Salt != "" {
		t.Fatalf("expected empty Salt (bcrypt embeds salt internally), got: %q", out.Salt)
	}
}

func TestCheckPassword_RoundTrip(t *testing.T) {
	p := NewCustomPassword()
	out := p.CreatePassword("correct horse battery staple")

	if !p.CheckPassword("correct horse battery staple", out.Hash, out.Salt) {
		t.Fatal("expected correct password to verify")
	}
	if p.CheckPassword("wrong", out.Hash, out.Salt) {
		t.Fatal("expected wrong password to fail verification")
	}
}

func TestCheckPassword_RejectsLegacyMD5Hash(t *testing.T) {
	p := NewCustomPassword()
	// 32-char hex string mimicking the old MD5 output: must always fail.
	legacy := "5f4dcc3b5aa765d61d8327deb882cf99"
	if p.CheckPassword("password", legacy, "anysalt") {
		t.Fatal("legacy MD5-shaped hash must not verify under bcrypt")
	}
}

func TestCheckPassword_EmptyHashFails(t *testing.T) {
	p := NewCustomPassword()
	if p.CheckPassword("anything", "", "") {
		t.Fatal("empty hash must never verify")
	}
}

func TestCreatePassword_DifferentEachCall(t *testing.T) {
	// bcrypt generates a fresh random salt each call, so identical inputs
	// must produce different hashes — a regression test for accidentally
	// reverting to a deterministic scheme.
	p := NewCustomPassword()
	a := p.CreatePassword("same-password")
	b := p.CreatePassword("same-password")
	if a.Hash == b.Hash {
		t.Fatal("two bcrypt hashes of the same password must differ")
	}
}
