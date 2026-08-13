package config

import (
	"github.com/mmtaee/ocserv-dashboard/common/pkg/logger"
	"os"
	"strings"
)

type Config struct {
	Debug        bool
	Host         string
	Port         int
	SecretKey    string
	JWTSecret    string
	AllowOrigins []string
	DB           PostgresConfig
}

type PostgresConfig struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
	SSLMode  string
}

var cfg *Config

// Init loads configuration from the environment.
//
// Security note: there are no fallback defaults for SECRET_KEY and JWT_SECRET.
// Previous versions had hardcoded defaults like "secret1234"; if .env failed
// to load for any reason the API would silently sign JWTs with a publicly
// known value. We now fail fast (logger.Fatal) instead.
func Init(debug bool, host string, port int) {
	secretKey := os.Getenv("SECRET_KEY")
	if secretKey == "" {
		logger.Fatal("SECRET_KEY environment variable is not set; refusing to start with a default value")
	}
	if len(secretKey) < 16 {
		logger.Fatal("SECRET_KEY is too short (need at least 16 characters)")
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		logger.Fatal("JWT_SECRET environment variable is not set; refusing to start with a default value")
	}
	if len(jwtSecret) < 16 {
		logger.Fatal("JWT_SECRET is too short (need at least 16 characters)")
	}

	allowOrigins := os.Getenv("ALLOW_ORIGINS")
	if allowOrigins == "" {
		logger.Warn("ALLOW_ORIGINS environment variable not set — CORS will reject all browser origins")
	}

	cfg = &Config{
		Debug:        debug,
		Host:         host,
		Port:         port,
		SecretKey:    secretKey,
		JWTSecret:    jwtSecret,
		AllowOrigins: strings.Split(allowOrigins, ","),
		DB:           loadDatabaseEnv(),
	}
}

func loadDatabaseEnv() PostgresConfig {
	host := getEnv("POSTGRES_HOST", "127.0.0.1")
	port := getEnv("POSTGRES_PORT", "5432")
	user := getEnv("POSTGRES_USER", "ocserv")
	password := os.Getenv("POSTGRES_PASSWORD")
	dbName := getEnv("POSTGRES_DB", "ocserv_db")
	sslMode := getEnv("POSTGRES_SSLMODE", "disable")

	if password == "" {
		logger.Fatal("POSTGRES_PASSWORD environment variable is not set")
	}

	return PostgresConfig{
		Host:     host,
		Port:     port,
		User:     user,
		Password: password,
		DBName:   dbName,
		SSLMode:  sslMode,
	}
}

func Get() *Config {
	return cfg
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
