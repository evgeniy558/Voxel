package auth

import (
	"encoding/json"
	"net/http"

	"sphere-backend/internal/middleware"
)

type privacyUpdateReq struct {
	HideSubscriptions  *bool `json:"hide_subscriptions"`
	MessagesMutualOnly *bool `json:"messages_mutual_only"`
	PrivateProfile     *bool `json:"private_profile"`
}

func (h *AccountHandler) UpdatePrivacy(w http.ResponseWriter, r *http.Request) {
	userID := middleware.GetUserID(r.Context())
	var req privacyUpdateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, http.StatusBadRequest)
		return
	}

	u, err := h.UserSvc.GetByID(r.Context(), userID)
	if err != nil {
		http.Error(w, `{"error":"user not found"}`, http.StatusNotFound)
		return
	}

	hide := u.HideSubscriptions
	mutual := u.MessagesMutualOnly
	priv := u.PrivateProfile
	if req.HideSubscriptions != nil {
		hide = *req.HideSubscriptions
	}
	if req.MessagesMutualOnly != nil {
		mutual = *req.MessagesMutualOnly
	}
	if req.PrivateProfile != nil {
		priv = *req.PrivateProfile
	}

	updated, err := h.UserSvc.UpdatePrivacy(r.Context(), userID, hide, mutual, priv)
	if err != nil {
		http.Error(w, `{"error":"update failed"}`, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(updated)
}

