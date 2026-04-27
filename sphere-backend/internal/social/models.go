package social

import "time"

type UserListItem struct {
	ID        string `json:"id"`
	Username  string `json:"username"`
	Name      string `json:"name"`
	AvatarURL string `json:"avatar_url"`

	IsVerified bool   `json:"is_verified"`
	BadgeText  string `json:"badge_text"`
	BadgeColor string `json:"badge_color"`

	PrivateProfile bool `json:"private_profile"`
}

type ProfileStats struct {
	MonthlyListens     int `json:"monthly_listens"`
	SubscribersCount   int `json:"subscribers_count"`
	SubscriptionsCount int `json:"subscriptions_count"`
}

type ProfileResponse struct {
	User  UserListItem  `json:"user"`
	Stats ProfileStats  `json:"stats"`

	IsSubscribed bool   `json:"is_subscribed"`
	RequestStatus string `json:"subscription_request_status,omitempty"` // pending/approved/denied/cancelled/none

	HideSubscriptions bool `json:"hide_subscriptions"`
	PrivateProfile    bool `json:"private_profile"`

	RequiresApproval bool `json:"requires_approval"`
	CanMessage       bool `json:"can_message"`
}

type HiddenListResponse struct {
	Hidden bool `json:"hidden"`
}

type SubscriptionRequestItem struct {
	ID        string    `json:"id"`
	Requester UserListItem `json:"requester"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

