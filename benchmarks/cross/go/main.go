// Cross-framework benchmark server — Go net/http (std lib only).
// Routes match the zax and axum servers 1:1:
//
//	GET  /            -> "hello"
//	GET  /users/{id}  -> the captured id
//	POST /echo        -> JSON echo of {"msg": "..."}
//	GET  /large       -> buffered ~PAYLOAD_KB KB JSON body
//
// Requires Go 1.22+ (method+pattern ServeMux). Run: `go run .` (listens on :8083).
package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
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

	largeKB := 64
	if v := os.Getenv("PAYLOAD_KB"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			largeKB = n
		}
	}
	largeBuf := make([]byte, largeKB*1024)
	copy(largeBuf, []byte(`{"data":"`))
	for i := len(`{"data":"`); i < len(largeBuf)-2; i++ {
		largeBuf[i] = 'x'
	}
	copy(largeBuf[len(largeBuf)-2:], []byte(`"}`))
	mux.HandleFunc("GET /large", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(largeBuf)
	})

	const addr = "127.0.0.1:8083"
	log.Printf("go bench server on http://%s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
