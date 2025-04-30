;; Clarity Contract for CryptoScope On-Chain Analytics
;; Name: cryptoscope-core
;; Purpose: Manages wallet monitoring subscriptions and on-chain activity tracking on Stacks blockchain

;; Error Constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-ADDRESS (err u101))
(define-constant ERR-ALREADY-SUBSCRIBED (err u102))
(define-constant ERR-NOT-FOUND (err u103))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u104))
(define-constant ERR-INVALID-PARAMETERS (err u105))
(define-constant ERR-PAYMENT-FAILED (err u106))
(define-constant ERR-NOT-SUBSCRIPTION-OWNER (err u107))
(define-constant ERR-INSUFFICIENT-FUNDS (err u108))

;; Constants
(define-constant SUBSCRIPTION-DURATION u2880) ;; Subscription duration in blocks (approximately 30 days)
(define-constant SUBSCRIPTION-FEE u10000000) ;; 10 STX subscription fee
(define-constant CONTRACT-OWNER tx-sender)   ;; Sets deployer as contract owner

;; Data Maps
;; Subscription registry: Maps subscription ID to subscription details
(define-map subscriptions
  { subscription-id: uint }
  {
    owner: principal,
    monitored-address: principal,
    subscription-expiry: uint,
    alert-frequency: uint,            ;; How often to check (in blocks)
    min-transaction-value: uint,      ;; Minimum STX value to trigger alert
    track-stx-transfers: bool,        ;; Whether to track STX transfers
    track-asset-transfers: bool,      ;; Whether to track SIP-009/SIP-010 transfers
    track-contract-calls: bool,       ;; Whether to track contract calls
    custom-notes: (string-ascii 256)  ;; User notes about this subscription
  }
)

;; Address monitoring: Maps address to array of subscription IDs
(define-map address-monitoring
  { address: principal }
  { subscription-ids: (list 20 uint) }
)

;; User subscriptions: Maps user to their subscription IDs
(define-map user-subscriptions
  { user: principal }
  { subscription-ids: (list 50 uint) }
)

;; Data Variables
(define-data-var last-subscription-id uint u0)
(define-data-var total-subscriptions uint u0)
(define-data-var total-active-subscriptions uint u0)

;; Private Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-subscription-owner (subscription-id uint))
  (match (map-get? subscriptions { subscription-id: subscription-id })
    subscription (is-eq tx-sender (get owner subscription))
    false
  )
)

(define-private (is-valid-address (address principal))
  ;; Simple check to validate address - in a real implementation,
  ;; this might have more sophisticated validation
  (not (is-eq address CONTRACT-OWNER))
)

(define-private (get-next-subscription-id)
  (let ((next-id (+ (var-get last-subscription-id) u1)))
    (var-set last-subscription-id next-id)
    next-id
  )
)

(define-private (add-subscription-to-list (list (list 50 uint)) (subscription-id uint))
  (unwrap-panic (as-max-len? (append list subscription-id) u50))
)

(define-private (is-subscription-active (subscription-id uint))
  (match (map-get? subscriptions { subscription-id: subscription-id })
    subscription (> (get subscription-expiry subscription) block-height)
    false
  )
)

(define-private (update-subscription-metrics (is-new bool) (is-renewal bool))
  (begin
    (if is-new
      (var-set total-subscriptions (+ (var-get total-subscriptions) u1))
      true
    )
    
    (if (and is-new (not is-renewal))
      (var-set total-active-subscriptions (+ (var-get total-active-subscriptions) u1))
      (if (and (not is-new) is-renewal)
        (var-set total-active-subscriptions (+ (var-get total-active-subscriptions) u1))
        true
      )
    )
    true
  )
)

;; Read-only Functions
(define-read-only (get-subscription-details (subscription-id uint))
  (match (map-get? subscriptions { subscription-id: subscription-id })
    subscription (ok subscription)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-user-subscriptions (user principal))
  (match (map-get? user-subscriptions { user: user })
    subscription-list (ok subscription-list)
    (ok { subscription-ids: (list) })
  )
)

(define-read-only (get-address-subscriptions (address principal))
  (match (map-get? address-monitoring { address: address })
    subscription-list (ok subscription-list)
    (ok { subscription-ids: (list) })
  )
)

(define-read-only (is-address-monitored (address principal))
  (match (map-get? address-monitoring { address: address })
    subscription-list 
      (> (len (get subscription-ids subscription-list)) u0)
    false
  )
)

(define-read-only (get-subscription-price)
  SUBSCRIPTION_FEE
)

(define-read-only (get-subscription-stats)
  {
    total-subscriptions: (var-get total-subscriptions),
    active-subscriptions: (var-get total-active-subscriptions),
    current-block: block-height
  }
)

;; Public Functions
(define-public (create-subscription 
  (monitored-address principal)
  (alert-frequency uint)
  (min-transaction-value uint)
  (track-stx-transfers bool)
  (track-asset-transfers bool)
  (track-contract-calls bool)
  (custom-notes (string-ascii 256))
)
  (let (
    (subscription-id (get-next-subscription-id))
    (subscription-expiry (+ block-height SUBSCRIPTION-DURATION))
    (sender tx-sender)
    (user-subs (default-to { subscription-ids: (list) } 
                (map-get? user-subscriptions { user: sender })))
    (address-subs (default-to { subscription-ids: (list) } 
                  (map-get? address-monitoring { address: monitored-address })))
  )
    ;; Validations
    (asserts! (is-valid-address monitored-address) ERR-INVALID-ADDRESS)
    (asserts! (> alert-frequency u0) ERR-INVALID-PARAMETERS)
    (asserts! (or track-stx-transfers track-asset-transfers track-contract-calls) ERR-INVALID-PARAMETERS)
    
    ;; Process payment
    (asserts! (>= (stx-get-balance tx-sender) SUBSCRIPTION-FEE) ERR-INSUFFICIENT-FUNDS)
    (try! (stx-transfer? SUBSCRIPTION-FEE tx-sender CONTRACT-OWNER))
    
    ;; Create subscription
    (map-set subscriptions
      { subscription-id: subscription-id }
      {
        owner: sender,
        monitored-address: monitored-address,
        subscription-expiry: subscription-expiry,
        alert-frequency: alert-frequency,
        min-transaction-value: min-transaction-value,
        track-stx-transfers: track-stx-transfers,
        track-asset-transfers: track-asset-transfers,
        track-contract-calls: track-contract-calls,
        custom-notes: custom-notes
      }
    )
    
    ;; Update user subscriptions list
    (map-set user-subscriptions
      { user: sender }
      { subscription-ids: (add-subscription-to-list (get subscription-ids user-subs) subscription-id) }
    )
    
    ;; Update address monitoring list
    (map-set address-monitoring
      { address: monitored-address }
      { subscription-ids: (add-subscription-to-list (get subscription-ids address-subs) subscription-id) }
    )
    
    ;; Update metrics
    (update-subscription-metrics true false)
    
    (ok subscription-id)
  )
)

(define-public (renew-subscription (subscription-id uint))
  (let (
    (subscription (unwrap! (map-get? subscriptions { subscription-id: subscription-id }) ERR-NOT-FOUND))
    (current-expiry (get subscription-expiry subscription))
    (new-expiry (+ (if (> current-expiry block-height) 
                      current-expiry 
                      block-height) 
                   SUBSCRIPTION-DURATION))
  )
    ;; Check authorization
    (asserts! (is-eq (get owner subscription) tx-sender) ERR-NOT-SUBSCRIPTION-OWNER)
    
    ;; Process payment
    (asserts! (>= (stx-get-balance tx-sender) SUBSCRIPTION-FEE) ERR-INSUFFICIENT-FUNDS)
    (try! (stx-transfer? SUBSCRIPTION-FEE tx-sender CONTRACT-OWNER))
    
    ;; Update subscription expiry
    (map-set subscriptions
      { subscription-id: subscription-id }
      (merge subscription { subscription-expiry: new-expiry })
    )
    
    ;; Update metrics for renewal
    (update-subscription-metrics false (< current-expiry block-height))
    
    (ok new-expiry)
  )
)

(define-public (update-subscription-parameters
  (subscription-id uint)
  (alert-frequency uint)
  (min-transaction-value uint)
  (track-stx-transfers bool)
  (track-asset-transfers bool)
  (track-contract-calls bool)
  (custom-notes (string-ascii 256))
)
  (let (
    (subscription (unwrap! (map-get? subscriptions { subscription-id: subscription-id }) ERR-NOT-FOUND))
  )
    ;; Validations
    (asserts! (is-subscription-owner subscription-id) ERR-NOT-SUBSCRIPTION-OWNER)
    (asserts! (is-subscription-active subscription-id) ERR-SUBSCRIPTION-EXPIRED)
    (asserts! (> alert-frequency u0) ERR-INVALID-PARAMETERS)
    (asserts! (or track-stx-transfers track-asset-transfers track-contract-calls) ERR-INVALID-PARAMETERS)
    
    ;; Update subscription
    (map-set subscriptions
      { subscription-id: subscription-id }
      (merge subscription { 
        alert-frequency: alert-frequency,
        min-transaction-value: min-transaction-value,
        track-stx-transfers: track-stx-transfers,
        track-asset-transfers: track-asset-transfers,
        track-contract-calls: track-contract-calls,
        custom-notes: custom-notes
      })
    )
    
    (ok true)
  )
)

(define-public (cancel-subscription (subscription-id uint))
  (let (
    (subscription (unwrap! (map-get? subscriptions { subscription-id: subscription-id }) ERR-NOT-FOUND))
  )
    ;; Validations
    (asserts! (is-subscription-owner subscription-id) ERR-NOT-SUBSCRIPTION-OWNER)
    
    ;; Update subscription expiry to current block (effectively canceling it)
    (map-set subscriptions
      { subscription-id: subscription-id }
      (merge subscription { subscription-expiry: block-height })
    )
    
    ;; Update metrics
    (var-set total-active-subscriptions (- (var-get total-active-subscriptions) u1))
    
    (ok true)
  )
)

;; Contract owner functions
(define-public (withdraw-fees (amount uint) (recipient principal))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (try! (as-contract (stx-transfer? amount CONTRACT-OWNER recipient)))
    (ok amount)
  )
)

(define-public (update-subscription-duration (new-duration uint))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (asserts! (> new-duration u0) ERR-INVALID-PARAMETERS)
    (ok (var-set SUBSCRIPTION-DURATION new-duration))
  )
)

(define-public (update-subscription-fee (new-fee uint))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (asserts! (> new-fee u0) ERR-INVALID-PARAMETERS)
    (ok (var-set SUBSCRIPTION-FEE new-fee))
  )
)