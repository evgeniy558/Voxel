package middleware

import (
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
)

// AdminOnly allows requests where JWT user has is_admin = true in Postgres.
func AdminOnly(pool *pgxpool.Pool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := GetUserID(r.Context())
			if id == "" {
				http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
				return
			}
			var ok bool
			err := pool.QueryRow(r.Context(), `SELECT COALESCE(is_admin,false) FROM users WHERE id = $1::uuid`, id).Scan(&ok)
			if err != nil || !ok {
				http.Error(w, `{"error":"admin only"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
