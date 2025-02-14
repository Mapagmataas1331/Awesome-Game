package main

import (
	"log"
	"net/http"
	"os"

	"github.com/gorilla/websocket"
)

var (
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
	clients = make(map[*websocket.Conn]bool)
)

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Upgrade error: %v\n", err)
		return
	}
	defer ws.Close()
	clients[ws] = true
	log.Println("Client connected")

	for {
		messageType, msg, err := ws.ReadMessage()
		if err != nil {
			log.Printf("Read error: %v\n", err)
			delete(clients, ws)
			break
		}
		log.Printf("Received: %s\n", msg)

		for client := range clients {
			if client != ws && client.WriteMessage(messageType, msg) != nil {
				client.Close()
				delete(clients, client)
			}
		}
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/ws", handleWebSocket)

	log.Printf("WebSocket signaling server running on port %s\n", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("ListenAndServe: %v", err)
	}
}
