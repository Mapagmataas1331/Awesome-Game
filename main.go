package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
)

const (
	LobbyTTL        = 30 * time.Minute
	CleanupInterval = 5 * time.Minute
	WriteWait       = 10 * time.Second
	PongWait        = 60 * time.Second
	PingPeriod      = (PongWait * 9) / 10
	MaxMessageSize  = 1024
)

type Client struct {
	Conn      *websocket.Conn
	ID        string
	LobbyCode string
}

type Lobby struct {
	Code      string
	CreatedAt time.Time
	Clients   map[string]*Client // ID -> Client
	HostID    string
	mu        sync.RWMutex
}

var (
	upgrader = websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin:     checkOrigin,
	}
	lobbies   = sync.Map{}
	clientMap = sync.Map{} // websocket.Conn -> Client
)

func main() {
	log.Printf("[INFO] Starting WebSocket server on port %s", getPort())
	go cleanupExpiredLobbies()
	http.HandleFunc("/", handleWebSocket)
	server := &http.Server{
		Addr:              ":" + getPort(),
		ReadHeaderTimeout: 3 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("[ERROR] ListenAndServe error: %v", err)
	}
}

func checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true // Allow non-browser clients
	}
	return origin == AllowedOrigin
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ERROR] Upgrade error: %v", err)
		return
	}

	log.Printf("[INFO] New connection from %s", r.RemoteAddr)
	client := &Client{
		Conn: ws,
		ID:   generateClientID(r),
	}
	clientMap.Store(ws, client)

	defer func() {
		cleanupConnection(client)
		ws.Close()
	}()

	ws.SetReadLimit(MaxMessageSize)
	ws.SetReadDeadline(time.Now().Add(PongWait))
	ws.SetPongHandler(func(string) error {
		ws.SetReadDeadline(time.Now().Add(PongWait))
		return nil
	})

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway) {
				log.Printf("[ERROR] Read error: %v", err)
			}
			break
		}

		if !utf8.Valid(msg) {
			log.Printf("[WARN] Invalid UTF-8 message from %s", client.ID)
			continue
		}

		var baseMsg struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(msg, &baseMsg); err != nil {
			log.Printf("[ERROR] Message parse error: %v", err)
			continue
		}

		switch baseMsg.Type {
		case "register", "join", "unregister":
			handleControlMessage(client, msg)
		case "offer", "answer", "ice", "chat":
			handleGameMessage(client, msg)
		case "ping":
			handlePing(client)
		default:
			log.Printf("[WARN] Unknown message type: %s", baseMsg.Type)
		}
	}
}

func handleControlMessage(client *Client, rawMsg []byte) {
	var msg struct {
		Type string `json:"type"`
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rawMsg, &msg); err != nil {
		log.Printf("[ERROR] Control message parse error: %v", err)
		return
	}

	switch msg.Type {
	case "register":
		handleLobbyRegistration(client, msg.Code)
	case "join":
		handleLobbyJoin(client, msg.Code)
	case "unregister":
		handleLobbyUnregistration(client, msg.Code)
	}
}

func handleGameMessage(sender *Client, rawMsg []byte) {
	lobbyInterface, ok := lobbies.Load(sender.LobbyCode)
	if !ok {
		log.Printf("[WARN] Lobby not found for client %s", sender.ID)
		return
	}

	lobby := lobbyInterface.(*Lobby)
	lobby.mu.RLock()
	defer lobby.mu.RUnlock()

	broadcastMessage(lobby, sender.ID, rawMsg)
}

func handleLobbyRegistration(client *Client, code string) {
	if code == "" {
		code = generateLobbyCode()
	}

	newLobby := &Lobby{
		Code:      code,
		CreatedAt: time.Now(),
		Clients:   make(map[string]*Client),
		HostID:    client.ID,
	}
	newLobby.Clients[client.ID] = client
	client.LobbyCode = code

	if _, loaded := lobbies.LoadOrStore(code, newLobby); loaded {
		sendError(client, "Lobby already exists")
		return
	}

	sendJSON(client, map[string]interface{}{
		"type": "lobby_created",
		"code": code,
	})
	log.Printf("[INFO] Lobby %s created by %s", code, client.ID)
}

func handleLobbyJoin(client *Client, code string) {
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		sendError(client, "Lobby not found")
		return
	}

	lobby := lobbyInterface.(*Lobby)
	lobby.mu.Lock()
	defer lobby.mu.Unlock()

	if _, exists := lobby.Clients[client.ID]; exists {
		sendError(client, "Already in lobby")
		return
	}

	lobby.Clients[client.ID] = client
	client.LobbyCode = code

	broadcastMessage(lobby, client.ID, createSystemMessage("player_joined", client.ID))

	sendJSON(client, map[string]interface{}{
		"type":    "lobby_joined",
		"code":    code,
		"members": getClientIDs(lobby),
	})
	log.Printf("[INFO] %s joined lobby %s", client.ID, code)
}

func handleLobbyUnregistration(client *Client, code string) {
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		sendError(client, "Lobby not found")
		return
	}

	lobby := lobbyInterface.(*Lobby)
	lobby.mu.Lock()
	defer lobby.mu.Unlock()

	if lobby.HostID != client.ID {
		sendError(client, "Only host can unregister lobby")
		return
	}

	closeLobby(lobby)
	log.Printf("[INFO] Lobby %s closed by host %s", code, client.ID)
}

func broadcastMessage(lobby *Lobby, senderID string, msg []byte) {
	for _, client := range lobby.Clients {
		if client.ID == senderID {
			continue
		}
		if err := writeWithTimeout(client.Conn, msg); err != nil {
			log.Printf("[WARN] Failed to send message to %s: %v", client.ID, err)
		}
	}
}

func cleanupConnection(client *Client) {
	if client.LobbyCode != "" {
		lobbyInterface, ok := lobbies.Load(client.LobbyCode)
		if ok {
			lobby := lobbyInterface.(*Lobby)
			lobby.mu.Lock()
			defer lobby.mu.Unlock()

			delete(lobby.Clients, client.ID)
			broadcastMessage(lobby, client.ID, createSystemMessage("player_left", client.ID))

			if len(lobby.Clients) == 0 {
				lobbies.Delete(client.LobbyCode)
			} else if lobby.HostID == client.ID {
				// Assign new host
				for _, newHost := range lobby.Clients {
					lobby.HostID = newHost.ID
					break
				}
				broadcastMessage(lobby, "", createSystemMessage("new_host", lobby.HostID))
			}
		}
	}
	clientMap.Delete(client.Conn)
	log.Printf("[INFO] Connection closed for %s", client.ID)
}

func cleanupExpiredLobbies() {
	for range time.Tick(CleanupInterval) {
		lobbies.Range(func(key, value interface{}) bool {
			lobby := value.(*Lobby)
			if time.Since(lobby.CreatedAt) > LobbyTTL {
				closeLobby(lobby)
				log.Printf("[INFO] Cleaned up expired lobby %s", key)
			}
			return true
		})
	}
}

func closeLobby(lobby *Lobby) {
	lobby.mu.Lock()
	defer lobby.mu.Unlock()

	for _, client := range lobby.Clients {
		client.Conn.WriteControl(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, "Lobby closed"),
			time.Now().Add(WriteWait),
		)
		client.Conn.Close()
	}
	lobbies.Delete(lobby.Code)
}

func writeWithTimeout(conn *websocket.Conn, msg []byte) error {
	conn.SetWriteDeadline(time.Now().Add(WriteWait))
	return conn.WriteMessage(websocket.TextMessage, msg)
}

func createSystemMessage(msgType, content string) []byte {
	msg, _ := json.Marshal(map[string]interface{}{
		"type":    "system",
		"subtype": msgType,
		"content": content,
	})
	return msg
}

func getClientIDs(lobby *Lobby) []string {
	ids := make([]string, 0, len(lobby.Clients))
	for id := range lobby.Clients {
		ids = append(ids, id)
	}
	return ids
}

func sendJSON(client *Client, data interface{}) {
	if err := writeWithTimeout(client.Conn, mustMarshal(data)); err != nil {
		log.Printf("[ERROR] Failed to send JSON to %s: %v", client.ID, err)
	}
}

func sendError(client *Client, message string) {
	sendJSON(client, map[string]interface{}{
		"type":    "error",
		"message": message,
	})
}

func mustMarshal(data interface{}) []byte {
	bytes, err := json.Marshal(data)
	if err != nil {
		log.Printf("[ERROR] JSON marshaling failed: %v", err)
		return []byte("{}")
	}
	return bytes
}

func generateClientID(r *http.Request) string {
	return r.RemoteAddr + "-" + time.Now().Format(time.RFC3339Nano)
}

func generateLobbyCode() string {
	return "RANDOMCODE"
}

func getPort() string {
	if port := os.Getenv("PORT"); port != "" {
		return port
	}
	return "8080"
}
