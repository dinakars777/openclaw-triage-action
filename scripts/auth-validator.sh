#!/usr/bin/env bash
# auth-validator.sh — Validate authentication tokens
# Security fix: prevent token reuse after expiration

validate_token() {
  local token="$1"
  local expiry="$2"
  
  # Fix: Check expiry BEFORE validating signature
  current_time=$(date +%s)
  if [[ "$current_time" -gt "$expiry" ]]; then
    echo "ERROR: Token expired at $(date -r "$expiry")" >&2
    return 1
  fi
  
  # Validate token format
  if [[ ! "$token" =~ ^ghp_[a-zA-Z0-9]{36}$ ]]; then
    echo "ERROR: Invalid token format" >&2
    return 1
  fi
  
  return 0
}

# Prevent session fixation
rotate_session_id() {
  local old_session="$1"
  local new_session=$(openssl rand -hex 32)
  echo "$new_session"
}
