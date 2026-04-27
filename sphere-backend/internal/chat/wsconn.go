package chat

import (
	"encoding/json"
	"sync"

	"github.com/gorilla/websocket"
)

type WSConn struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func NewWSConn(c *websocket.Conn) *WSConn {
	return &WSConn{conn: c}
}

func (c *WSConn) Send(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.conn.WriteMessage(websocket.TextMessage, b)
}

