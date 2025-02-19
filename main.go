package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"

	"github.com/gorilla/websocket"
)

var (
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
	clients     = make(map[*websocket.Conn]bool)
	clientLobby = make(map[*websocket.Conn]string)
	mu          sync.Mutex
)

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Upgrade error: %v\n", err)
		return
	}
	defer ws.Close()

	mu.Lock()
	clients[ws] = true
	mu.Unlock()
	log.Println("Client connected")

	for {
		messageType, msg, err := ws.ReadMessage()
		if err != nil {
			log.Printf("Read error: %v\n", err)
			mu.Lock()
			delete(clients, ws)
			delete(clientLobby, ws)
			mu.Unlock()
			break
		}
		log.Printf("Received: %s\n", msg)

		var data map[string]interface{}
		if err := json.Unmarshal(msg, &data); err != nil {
			log.Printf("JSON unmarshal error: %v\n", err)
			continue
		}

		if typ, ok := data["type"].(string); ok && typ == "register" {
			if code, ok := data["code"].(string); ok {
				mu.Lock()
				clientLobby[ws] = code
				mu.Unlock()
				log.Printf("Client registered in lobby: %s\n", code)
			}
		}

		var lobbyCode string
		if code, ok := data["code"].(string); ok {
			lobbyCode = code
		} else {
			mu.Lock()
			lobbyCode = clientLobby[ws]
			mu.Unlock()
		}

		mu.Lock()
		for client := range clients {
			if client == ws {
				continue
			}
			if clobby, exists := clientLobby[client]; exists && clobby == lobbyCode {
				if err := client.WriteMessage(messageType, msg); err != nil {
					client.Close()
					delete(clients, client)
					delete(clientLobby, client)
				}
			}
		}
		mu.Unlock()
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", handleWebSocket)
	log.Printf("WebSocket signaling server running on port %s\n", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}
