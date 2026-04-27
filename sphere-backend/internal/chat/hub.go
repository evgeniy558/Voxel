package chat

import (
	"sync"
)

type Hub struct {
	mu    sync.RWMutex
	conns map[string]map[*WSConn]struct{} // userID -> conns
}

func NewHub() *Hub {
	return &Hub{
		conns: make(map[string]map[*WSConn]struct{}),
	}
}

func (h *Hub) Register(userID string, c *WSConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[userID] == nil {
		h.conns[userID] = make(map[*WSConn]struct{})
	}
	h.conns[userID][c] = struct{}{}
}

func (h *Hub) Unregister(userID string, c *WSConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.conns[userID]
	if m == nil {
		return
	}
	delete(m, c)
	if len(m) == 0 {
		delete(h.conns, userID)
	}
}

func (h *Hub) Broadcast(userIDs []string, ev WSMessageEvent) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, uid := range userIDs {
		for c := range h.conns[uid] {
			c.Send(ev)
		}
	}
}

