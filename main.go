package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Lobby struct {
	Code      string
	CreatedAt time.Time
	Clients   []*websocket.Conn
}

var (
	upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	lobbies  = sync.Map{}
)

func main() {
	go cleanupExpiredLobbies()
	http.HandleFunc("/", handleWebSocket)
	log.Fatal(http.ListenAndServe(":"+getPort(), nil))
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("Upgrade error:", err)
		return
	}
	defer ws.Close()

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			break
		}

		var data map[string]interface{}
		if err := json.Unmarshal(msg, &data); err != nil {
			log.Println("Unmarshal error:", err)
			continue
		}

		switch data["type"] {
		case "register":
			handleRegistration(ws, data)
		case "join":
			handleJoin(ws, data)
		case "unregister":
			handleUnregistration(data)
		}
	}
}

func handleRegistration(ws *websocket.Conn, data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok {
		log.Println("Invalid code in registration")
		return
	}
	lobby := &Lobby{
		Code:      code,
		CreatedAt: time.Now(),
		Clients:   []*websocket.Conn{ws},
	}
	lobbies.Store(code, lobby)
}

func handleJoin(ws *websocket.Conn, data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok {
		log.Println("Invalid code in join")
		return
	}
	if lobbyInterface, ok := lobbies.Load(code); ok {
		lobby := lobbyInterface.(*Lobby)
		lobby.Clients = append(lobby.Clients, ws)
		broadcastToLobby(code, data)
	} else {
		log.Println("Lobby not found for code:", code)
	}
}

func handleUnregistration(data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok {
		log.Println("Invalid code in unregistration")
		return
	}
	lobbies.Delete(code)
}

func getPort() string {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	return port
}

func broadcastToLobby(code string, message map[string]interface{}) {
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		log.Println("Lobby not found for broadcasting:", code)
		return
	}
	lobby := lobbyInterface.(*Lobby)
	msgBytes, err := json.Marshal(message)
	if err != nil {
		log.Println("Error marshalling message:", err)
		return
	}
	for _, client := range lobby.Clients {
		if err := client.WriteMessage(websocket.TextMessage, msgBytes); err != nil {
			log.Println("Error sending message to client:", err)
		}
	}
}

func cleanupExpiredLobbies() {
	for {
		time.Sleep(5 * time.Minute)
		lobbies.Range(func(key, value interface{}) bool {
			if time.Since(value.(*Lobby).CreatedAt) > 30*time.Minute {
				lobbies.Delete(key)
			}
			return true
		})
	}
}
