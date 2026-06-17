// Cross-framework benchmark server — Go net/http (std lib only).
// Routes match the zax and axum servers 1:1:
//
//	GET  /            -> "hello"
//	GET  /users/{id}  -> the captured id
//	POST /echo        -> JSON echo of {"msg": "..."}
//
// Requires Go 1.22+ (method+pattern ServeMux). Run: `go run .` (listens on :8083).
package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
)

type msg struct {
	Msg string `json:"msg"`
}

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "hello")
	})

	mux.HandleFunc("GET /users/{id}", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, r.PathValue("id"))
	})

	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		var m msg
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(m)
	})

	const addr = "127.0.0.1:8083"
	log.Printf("go bench server on http://%s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
