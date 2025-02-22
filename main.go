package main

import (
	"crypto/rand"
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
	AllowedOrigin   = "yourgame.com"
	LobbyCodeLength = 6
	ClientIDLength  = 12
	PingMessageType = "ping"
	PongMessageType = "pong"
)

type Client struct {
	Conn      *websocket.Conn
	ID        string
	LobbyCode string
}

type Lobby struct {
	Code      string
	CreatedAt time.Time
	Clients   map[string]*Client
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
	clientMap = sync.Map{}
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
		return true
	}
	// return origin == AllowedOrigin
	return true
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	log.Printf("[DEBUG] Incoming connection to %s", r.URL.Path)
	log.Printf("[DEBUG] Headers: %+v", r.Header)

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		if websocket.IsUnexpectedCloseError(err) {
			log.Printf("[ERROR] Upgrade error: %v", err)
		} else {
			log.Printf("[WARN] Non-WebSocket request from %s: %v", r.RemoteAddr, err)
		}
		return
	}

	log.Printf("[INFO] New connection from %s (%s)", r.RemoteAddr, r.UserAgent())
	client := &Client{
		Conn: ws,
		ID:   generateClientID(),
	}
	clientMap.Store(ws, client)
	log.Printf("[CONNECT] New client %s connected", client.ID)

	go startPingRoutine(client)

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
		case PingMessageType:
			handleApplicationPing(client)
		default:
			log.Printf("[WARN] Unknown message type: %s", baseMsg.Type)
		}
	}
}

func startPingRoutine(client *Client) {
	ticker := time.NewTicker(PingPeriod)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if err := client.Conn.WriteControl(
				websocket.PingMessage,
				[]byte{},
				time.Now().Add(WriteWait),
			); err != nil {
				log.Printf("[WARN] Ping failed for %s: %v", client.ID, err)
				return
			}
		}
	}
}

func handleApplicationPing(client *Client) {
	sendJSON(client, map[string]string{
		"type": PongMessageType,
	})
	log.Printf("[PING] Received from %s", client.ID)
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
	log.Printf("[MSG] Received %d bytes from %s in lobby %s", len(rawMsg), sender.ID, sender.LobbyCode)
	if sender.LobbyCode == "" {
		log.Printf("[WARN] Client %s sent game message without lobby", sender.ID)
		return
	}

	lobbyInterface, ok := lobbies.Load(sender.LobbyCode)
	if !ok {
		log.Printf("[WARN] Lobby %s not found for client %s", sender.LobbyCode, sender.ID)
		return
	}

	lobby := lobbyInterface.(*Lobby)
	lobby.mu.RLock()
	defer lobby.mu.RUnlock()

	var baseMsg struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(rawMsg, &baseMsg); err == nil {
		log.Printf("[RELAY] %s %s -> %d peers", baseMsg.Type, sender.ID, len(lobby.Clients)-1)
	} else {
		log.Printf("[RELAY] Unknown message from %s", sender.ID)
	}

	broadcastMessage(lobby, sender.ID, rawMsg)
}

func handleLobbyRegistration(client *Client, code string) {
	if code == "" {
		code = generateLobbyCode()
		log.Printf("[INFO] Generated new code: %s for %s", code, client.ID)
	} else {
		log.Printf("[INFO] Received code: %s from %s", code, client.ID)
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
	log.Printf("[INFO] Client %s attempting to join %s", client.ID, code)
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		log.Printf("[WARN] Lobby %s not found for client %s", code, client.ID)
		sendError(client, "Lobby not found")
		return
	}

	lobby := lobbyInterface.(*Lobby)
	log.Printf("[INFO] Found lobby %s (created %s ago) with %d players",
		code, time.Since(lobby.CreatedAt).Round(time.Second), len(lobby.Clients))
	lobby.mu.Lock()
	defer lobby.mu.Unlock()

	if _, exists := lobby.Clients[client.ID]; exists {
		log.Printf("[WARN] Client %s already in lobby %s", client.ID, code)
		sendError(client, "Already in lobby")
		return
	}

	lobby.Clients[client.ID] = client
	client.LobbyCode = code

	broadcastMessage(lobby, client.ID, createSystemMessage("player_joined", client.ID))

	members := getClientIDs(lobby)
	log.Printf("[INFO] %s joined %s. Members: %v", client.ID, code, members)

	sendJSON(client, map[string]interface{}{
		"type":    "lobby_joined",
		"code":    code,
		"members": members,
	})
}

func handleLobbyUnregistration(client *Client, code string) {
	log.Printf("[INFO] Client %s attempting to unregister %s", client.ID, code)
	lobbyInterface, ok := lobbies.Load(code)
	if !ok {
		log.Printf("[WARN] Lobby %s not found for client %s", code, client.ID)
		sendError(client, "Lobby not found")
		return
	}

	log.Printf("[INFO] Found lobby %s (created %s ago) with %d players",
		code, time.Since(lobbyInterface.(*Lobby).CreatedAt).Round(time.Second), len(lobbyInterface.(*Lobby).Clients))

	lobby := lobbyInterface.(*Lobby)
	lobby.mu.Lock()
	defer lobby.mu.Unlock()

	if lobby.HostID != client.ID {
		log.Printf("[WARN] Client %s not host for lobby %s", client.ID, code)
		sendError(client, "Only host can unregister lobby")
		return
	}

	closeLobby(lobby)

	log.Printf("[INFO] Lobby %s closed by host %s", code, client.ID)
}

func broadcastMessage(lobby *Lobby, senderID string, msg []byte) {
	log.Printf("[BROADCAST] Lobby %s: Sending message from %s to %d peers",
		lobby.Code, senderID, len(lobby.Clients)-1)
	sentCount := 0
	start := time.Now()

	for _, client := range lobby.Clients {
		if client.ID == senderID {
			continue
		}
		if err := writeWithTimeout(client.Conn, msg); err != nil {
			log.Printf("[ERROR] Failed to send to %s: %v", client.ID, err)
		} else {
			sentCount++
		}
	}

	log.Printf("[BROADCAST] Completed in %v. Sent to %d/%d peers",
		time.Since(start), sentCount, len(lobby.Clients)-1)
}

func cleanupConnection(client *Client) {
	start := time.Now()
	defer func() {
		log.Printf("[DISCONNECT] Client %s cleanup completed in %v",
			client.ID, time.Since(start))
	}()

	if client.LobbyCode != "" {
		log.Printf("[DISCONNECT] Client %s leaving lobby %s", client.ID, client.LobbyCode)
		lobbyInterface, ok := lobbies.Load(client.LobbyCode)
		if ok {
			lobby := lobbyInterface.(*Lobby)
			lobby.mu.Lock()
			defer lobby.mu.Unlock()

			delete(lobby.Clients, client.ID)
			log.Printf("[LOBBY] Removed %s from %s. Remaining: %d",
				client.ID, lobby.Code, len(lobby.Clients))

			broadcastMessage(lobby, client.ID, createSystemMessage("player_left", client.ID))

			if len(lobby.Clients) == 0 {
				log.Printf("[LOBBY] Deleting empty lobby %s", lobby.Code)
				lobbies.Delete(client.LobbyCode)
			} else if lobby.HostID == client.ID {
				newHost := ""
				for _, nh := range lobby.Clients {
					newHost = nh.ID
					break
				}
				log.Printf("[HOST] Reassigning host from %s to %s in %s",
					client.ID, newHost, lobby.Code)
				lobby.HostID = newHost
				broadcastMessage(lobby, "", createSystemMessage("new_host", lobby.HostID))
			}
		}
	}
	clientMap.Delete(client.Conn)
	log.Printf("[DISCONNECT] Client %s fully removed", client.ID)
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
	start := time.Now()
	err := conn.WriteMessage(websocket.TextMessage, msg)

	if err != nil {
		log.Printf("[WS_ERROR] Write to %s failed after %v: %v",
			conn.RemoteAddr(), time.Since(start), err)
	} else {
		log.Printf("[WS_DEBUG] Wrote %d bytes to %s", len(msg), conn.RemoteAddr())
	}

	return err
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

func generateClientID() string {
	return randomString(ClientIDLength)
}

func generateLobbyCode() string {
	return randomString(LobbyCodeLength)
}

func randomString(length int) string {
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	rand.Read(b)
	for i := range b {
		b[i] = chars[b[i]%byte(len(chars))]
	}
	return string(b)
}

func getPort() string {
	if port := os.Getenv("PORT"); port != "" {
		return port
	}
	return "80"
}
