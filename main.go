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
	upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool { return true },
	}
	lobbies = sync.Map{}
)

func main() {
	log.Printf("[INFO] Starting WebSocket server on port %s", getPort())
	go cleanupExpiredLobbies()
	http.HandleFunc("/", handleWebSocket)
	if err := http.ListenAndServe(":"+getPort(), nil); err != nil {
		log.Fatalf("[ERROR] ListenAndServe error: %v", err)
	}
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ERROR] Upgrade error: %v", err)
		return
	}
	log.Printf("[INFO] New WebSocket connection from %s", r.RemoteAddr)
	defer ws.Close()

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			log.Printf("[INFO] Read error (closing connection): %v", err)
			break
		}
		var data map[string]interface{}
		if err := json.Unmarshal(msg, &data); err != nil {
			log.Printf("[ERROR] Unmarshal error: %v", err)
			continue
		}
		log.Printf("[INFO] Received message: %v", data)
		switch data["type"] {
		case "register":
			handleRegistration(ws, data)
		case "join":
			handleJoin(ws, data)
		case "unregister":
			handleUnregistration(data)
		case "player_update":
			handlePlayerUpdate(ws, data)
		default:
			log.Printf("[WARN] Unknown message type: %v", data["type"])
		}
	}
}

func handleRegistration(ws *websocket.Conn, data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok || code == "" {
		log.Println("[ERROR] Invalid or missing code in registration")
		return
	}
	lobby := &Lobby{
		Code:      code,
		CreatedAt: time.Now(),
		Clients:   []*websocket.Conn{ws},
	}
	lobbies.Store(code, lobby)
	log.Printf("[INFO] Lobby registered: %s at %s", code, lobby.CreatedAt.Format(time.RFC3339))

	resp := map[string]interface{}{
		"type": "code_registered",
		"code": code,
	}
	respBytes, err := json.Marshal(resp)
	if err != nil {
		log.Printf("[ERROR] Error marshalling response: %v", err)
		return
	}
	if err := ws.WriteMessage(websocket.TextMessage, respBytes); err != nil {
		log.Printf("[ERROR] Failed to send confirmation: %v", err)
		return
	}
	log.Printf("[INFO] Sent code_registered confirmation for lobby %s", code)
}

func handleJoin(ws *websocket.Conn, data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok || code == "" {
		log.Println("[ERROR] Invalid or missing code in join")
		return
	}
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		log.Printf("[WARN] Lobby not found for code: %s", code)
		return
	}
	lobby := lobbyInterface.(*Lobby)
	lobby.Clients = append(lobby.Clients, ws)
	log.Printf("[INFO] Client joined lobby %s; total clients: %d", code, len(lobby.Clients))
	broadcastToLobby(code, data)
}

func handleUnregistration(data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok || code == "" {
		log.Println("[ERROR] Invalid or missing code in unregistration")
		return
	}
	lobbies.Delete(code)
	log.Printf("[INFO] Lobby unregistered: %s", code)
}

func handlePlayerUpdate(ws *websocket.Conn, data map[string]interface{}) {
	code, ok := data["code"].(string)
	if !ok || code == "" {
		log.Println("[ERROR] player_update missing code")
		return
	}
	log.Printf("[INFO] Received player_update for lobby %s: %v", code, data)
	broadcastToLobby(code, data)
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
		log.Printf("[WARN] Lobby not found for broadcasting: %s", code)
		return
	}
	lobby := lobbyInterface.(*Lobby)
	msgBytes, err := json.Marshal(message)
	if err != nil {
		log.Printf("[ERROR] Error marshalling broadcast message: %v", err)
		return
	}
	log.Printf("[INFO] Broadcasting message to lobby %s (%d clients)", code, len(lobby.Clients))
	for i, client := range lobby.Clients {
		if err := client.WriteMessage(websocket.TextMessage, msgBytes); err != nil {
			log.Printf("[ERROR] Failed to send message to client %d in lobby %s: %v", i, code, err)
		} else {
			log.Printf("[INFO] Message sent to client %d in lobby %s", i, code)
		}
	}
}

func cleanupExpiredLobbies() {
	for {
		time.Sleep(5 * time.Minute)
		lobbies.Range(func(key, value interface{}) bool {
			lobby := value.(*Lobby)
			if time.Since(lobby.CreatedAt) > 30*time.Minute {
				lobbies.Delete(key)
				log.Printf("[INFO] Cleaned up expired lobby: %s", key)
			}
			return true
		})
	}
}
