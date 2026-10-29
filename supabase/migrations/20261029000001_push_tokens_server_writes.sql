-- Clients register push tokens through the register-push-token function (service role), never
-- directly: a direct insert could claim a token for another account or a flight not followed.
-- They keep read and delete (sign out removes the token). RLS owner policy still scopes both.
revoke insert, update on push_tokens from anon, authenticated;
