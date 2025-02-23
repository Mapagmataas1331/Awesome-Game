package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
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

var (
	debug      bool
	serverPort string
)

func debugLogf(format string, args ...interface{}) {
	if debug {
		log.Printf(format, args...)
	}
}

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

func init() {
	flag.BoolVar(&debug, "debug", false, "Enable debug logging")
	flag.StringVar(&serverPort, "port", "", "Server port")
	flag.Parse()

	if serverPort == "" {
		serverPort = os.Getenv("PORT")
		if serverPort == "" {
			serverPort = "80"
		}
	}
}

func main() {
	log.Printf("[INFO] Starting WebSocket server on port %s", serverPort)
	go cleanupExpiredLobbies()
	http.HandleFunc("/", handleWebSocket)
	server := &http.Server{
		Addr:              ":" + serverPort,
		ReadHeaderTimeout: 3 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("[ERROR] ListenAndServe error: %v", err)
	}
}

func checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	allowed := (origin == "" || origin == AllowedOrigin)
	debugLogf("[DEBUG] checkOrigin: Received origin '%s', allowed: %t", origin, allowed)
	return allowed
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	debugLogf("[DEBUG] Incoming connection to %s", r.URL.Path)
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ERROR] Upgrade error: %v", err)
		return
	}
	debugLogf("[INFO] New connection established from %s", r.RemoteAddr)
	client := &Client{
		Conn: ws,
		ID:   generateClientID(),
	}
	clientMap.Store(ws, client)
	log.Printf("[INFO] Client connected: %s", client.ID)
	go startPingRoutine(client)
	defer func() {
		debugLogf("[INFO] Cleaning up connection for client %s", client.ID)
		cleanupConnection(client)
		ws.Close()
	}()

	ws.SetReadLimit(MaxMessageSize)
	ws.SetReadDeadline(time.Now().Add(PongWait))
	ws.SetPongHandler(func(string) error {
		ws.SetReadDeadline(time.Now().Add(PongWait))
		debugLogf("[DEBUG] Pong received for client %s", client.ID)
		return nil
	})

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			log.Printf("[ERROR] Read error for client %s: %v", client.ID, err)
			break
		}
		if !utf8.Valid(msg) {
			log.Printf("[WARN] Invalid UTF-8 message from client %s", client.ID)
			continue
		}
		var baseMsg struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(msg, &baseMsg); err != nil {
			log.Printf("[ERROR] Message parse error from client %s: %v", client.ID, err)
			continue
		}
		debugLogf("[DEBUG] Received message type '%s' from client %s", baseMsg.Type, client.ID)
		switch baseMsg.Type {
		case "register", "join", "unregister":
			handleControlMessage(client, msg)
		case "offer", "answer", "ice", "chat":
			handleGameMessage(client, msg)
		case PingMessageType:
			handleApplicationPing(client)
		default:
			log.Printf("[WARN] Unknown message type '%s' from client %s", baseMsg.Type, client.ID)
		}
	}
}

func startPingRoutine(client *Client) {
	ticker := time.NewTicker(PingPeriod)
	defer ticker.Stop()
	debugLogf("[DEBUG] Starting ping routine for client %s", client.ID)
	for {
		select {
		case <-ticker.C:
			if err := client.Conn.WriteControl(websocket.PingMessage, []byte{}, time.Now().Add(WriteWait)); err != nil {
				log.Printf("[WARN] Ping failed for client %s: %v", client.ID, err)
				return
			} else {
				debugLogf("[DEBUG] Ping sent successfully to client %s", client.ID)
			}
		}
	}
}

func handleApplicationPing(client *Client) {
	sendJSON(client, map[string]string{"type": PongMessageType})
	debugLogf("[INFO] Responded with pong to client %s", client.ID)
}

func handleControlMessage(client *Client, rawMsg []byte) {
	var msg struct {
		Type string `json:"type"`
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rawMsg, &msg); err != nil {
		log.Printf("[ERROR] Control message parse error for client %s: %v", client.ID, err)
		return
	}
	debugLogf("[DEBUG] Handling control message '%s' for client %s with code '%s'", msg.Type, client.ID, msg.Code)
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
	if sender.LobbyCode == "" {
		log.Printf("[WARN] Client %s sent game message without a lobby", sender.ID)
		return
	}
	lobbyInterface, ok := lobbies.Load(sender.LobbyCode)
	if !ok {
		log.Printf("[WARN] Lobby '%s' not found for client %s", sender.LobbyCode, sender.ID)
		return
	}
	lobby := lobbyInterface.(*Lobby)
	lobby.mu.RLock()
	defer lobby.mu.RUnlock()
	var baseMsg struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(rawMsg, &baseMsg); err == nil {
		debugLogf("[DEBUG] Relaying message type '%s' from client %s to %d peers", baseMsg.Type, sender.ID, len(lobby.Clients)-1)
	}
	broadcastMessage(lobby, sender.ID, rawMsg)
}

func handleLobbyRegistration(client *Client, code string) {
	debugLogf("[INFO] Client %s requested lobby registration with code '%s'", client.ID, code)
	if client.LobbyCode != "" {
		if lobbyInterface, ok := lobbies.Load(client.LobbyCode); ok {
			lobby := lobbyInterface.(*Lobby)
			debugLogf("[INFO] Client %s already in lobby '%s'; removing from previous lobby", client.ID, client.LobbyCode)
			delete(lobby.Clients, client.ID)
		}
	}
	if code == "" {
		code = generateLobbyCode()
		debugLogf("[INFO] Generated new lobby code '%s' for client %s", code, client.ID)
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
		"id":   client.ID,
	})
	log.Printf("[INFO] Lobby '%s' created successfully by client %s", code, client.ID)
}

func handleLobbyJoin(client *Client, code string) {
	debugLogf("[INFO] Client %s attempting to join lobby '%s'", client.ID, code)
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
	log.Printf("[INFO] Client %s joined lobby '%s'", client.ID, code)
	broadcastMessage(lobby, client.ID, createSystemMessage("player_joined", client.ID))
	sendJSON(client, map[string]interface{}{
		"type": "lobby_joined",
		"code": code,
		"id":   client.ID,
	})
}

func handleLobbyUnregistration(client *Client, code string) {
	debugLogf("[INFO] Client %s requested to unregister lobby '%s'", client.ID, code)
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
	log.Printf("[INFO] Lobby '%s' closed by host %s", code, client.ID)
}

func broadcastMessage(lobby *Lobby, senderID string, msg []byte) {
	sentCount := 0
	start := time.Now()
	for _, client := range lobby.Clients {
		if client.ID == senderID {
			continue
		}
		if err := writeWithTimeout(client.Conn, msg); err != nil {
			log.Printf("[ERROR] Failed to send message to client %s: %v", client.ID, err)
		} else {
			sentCount++
			debugLogf("[DEBUG] Message sent to client %s", client.ID)
		}
	}
	debugLogf("[INFO] Broadcast completed in %v. Message sent to %d/%d peers",
		time.Since(start), sentCount, len(lobby.Clients)-1)
}

func cleanupConnection(client *Client) {
	debugLogf("[INFO] Starting cleanup for client %s", client.ID)
	if client.LobbyCode != "" {
		if lobbyInterface, ok := lobbies.Load(client.LobbyCode); ok {
			lobby := lobbyInterface.(*Lobby)
			lobby.mu.Lock()
			defer lobby.mu.Unlock()
			delete(lobby.Clients, client.ID)
			debugLogf("[INFO] Removed client %s from lobby '%s'", client.ID, client.LobbyCode)
			broadcastMessage(lobby, client.ID, createSystemMessage("player_left", client.ID))
			if len(lobby.Clients) == 0 {
				debugLogf("[INFO] Lobby '%s' is now empty and will be deleted", client.LobbyCode)
				lobbies.Delete(client.LobbyCode)
			} else if lobby.HostID == client.ID {
				var newHost string
				for _, nh := range lobby.Clients {
					newHost = nh.ID
					break
				}
				lobby.HostID = newHost
				log.Printf("[INFO] Host left. New host for lobby '%s' is %s", client.LobbyCode, newHost)
				broadcastMessage(lobby, "", createSystemMessage("new_host", lobby.HostID))
			}
		}
	}
	clientMap.Delete(client.Conn)
	log.Printf("[INFO] Cleanup complete for client %s", client.ID)
}

func cleanupExpiredLobbies() {
	ticker := time.NewTicker(CleanupInterval)
	defer ticker.Stop()
	debugLogf("[INFO] Started expired lobby cleanup routine")
	for range ticker.C {
		lobbies.Range(func(key, value interface{}) bool {
			lobby := value.(*Lobby)
			if time.Since(lobby.CreatedAt) > LobbyTTL {
				debugLogf("[INFO] Lobby '%s' expired; closing", key)
				closeLobby(lobby)
				debugLogf("[INFO] Cleaned up expired lobby '%s'", key)
			}
			return true
		})
	}
}

func closeLobby(lobby *Lobby) {
	log.Printf("[INFO] Closing lobby '%s' with %d client(s)", lobby.Code, len(lobby.Clients))
	for _, client := range lobby.Clients {
		client.LobbyCode = ""
		err := client.Conn.WriteControl(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, "Lobby closed"),
			time.Now().Add(WriteWait),
		)
		if err != nil {
			log.Printf("[ERROR] Error closing connection for client %s: %v", client.ID, err)
		}
		client.Conn.Close()
	}
	lobbies.Delete(lobby.Code)
	debugLogf("[INFO] Lobby '%s' has been deleted", lobby.Code)
}

func writeWithTimeout(conn *websocket.Conn, msg []byte) error {
	start := time.Now()
	err := conn.WriteMessage(websocket.TextMessage, msg)
	if err != nil {
		log.Printf("[ERROR] Write failed to %s after %v: %v", conn.RemoteAddr(), time.Since(start), err)
	} else {
		debugLogf("[DEBUG] Wrote %d bytes to %s", len(msg), conn.RemoteAddr())
	}
	return err
}

func createSystemMessage(msgType, content string) []byte {
	msg, _ := json.Marshal(map[string]interface{}{
		"type":    "system",
		"subtype": msgType,
		"content": content,
	})
	debugLogf("[DEBUG] Created system message: type=%s, content=%s", msgType, content)
	return msg
}

func sendJSON(client *Client, data interface{}) {
	if err := writeWithTimeout(client.Conn, mustMarshal(data)); err != nil {
		log.Printf("[ERROR] Failed to send JSON to client %s: %v", client.ID, err)
	} else {
		debugLogf("[DEBUG] JSON sent to client %s", client.ID)
	}
}

func sendError(client *Client, message string) {
	log.Printf("[ERROR] Sending error to client %s: %s", client.ID, message)
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
	id := randomString(ClientIDLength)
	debugLogf("[DEBUG] Generated client ID: %s", id)
	return id
}

func generateLobbyCode() string {
	code := randomString(LobbyCodeLength)
	debugLogf("[DEBUG] Generated lobby code: %s", code)
	return code
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
