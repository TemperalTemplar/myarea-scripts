#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# MyArea — Master Deploy Script v2
# Deploys Social app, Crime Wars engine, and Games Hub.
#
# Fixes from v1:
#  - Uses db.create_all() instead of flask db upgrade (avoids
#    Alembic DROP TABLE conflicts on fresh installs)
#  - Uses flask db stamp head after table creation
#  - Admin creation uses direct Python (avoids TTY issues)
#  - Restarts nginx after web container starts (fixes stale IP)
#  - Adds resolver 127.0.0.11 to nginx configs
#  - Removes SERVER_NAME (causes 404s behind reverse proxy)
#  - Uses docker compose up -d (not restart) to pick up .env changes
#  - Reconnects shared network after docker compose down
#
# Usage:
#   chmod +x deploy_myarea_v2.sh
#   ./deploy_myarea_v2.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${NC}"; }
error()   { echo -e "${RED}❌ $*${NC}"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

SOCIAL_ZIP="myarea_social_connected.zip"
ENGINE_ZIP="myarea_engine_connected.zip"
HUB_ZIP="myarea_hub.zip"
SOCIAL_DIR="myarea_social"
ENGINE_DIR="myarea_engine"
HUB_DIR="myarea_hub"
SHARED_NETWORK="myarea_shared_net"
SOCIAL_PORT="8920"
ENGINE_PORT="8921"
HUB_PORT="8918"

gen_secret() { openssl rand -hex 32; }

wait_healthy() {
    local container="$1" label="$2" max_wait=120 waited=0
    echo -n "   Waiting for $label"
    while ! docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | grep -q "healthy"; do
        sleep 3; waited=$((waited+3)); echo -n "."
        [ "$waited" -ge "$max_wait" ] && echo "" && error "$label timeout"
    done
    echo " ready!"
}

wait_web() {
    local container="$1" label="$2" max_wait=60 waited=0
    echo -n "   Waiting for $label web"
    while ! docker exec "$container" curl -sf "http://localhost:5000/" > /dev/null 2>&1; do
        sleep 3; waited=$((waited+3)); echo -n "."
        [ "$waited" -ge "$max_wait" ] && echo "" && warn "$label slow to respond" && return
    done
    echo " up!"
}

# ─── Step 0: Check requirements ───────────────────────────────
section "Checking requirements"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ ! -f "$SOCIAL_ZIP" ] && error "Cannot find $SOCIAL_ZIP"
[ ! -f "$ENGINE_ZIP" ] && error "Cannot find $ENGINE_ZIP"
command -v docker &>/dev/null || error "Docker not installed"
docker info &>/dev/null || error "Docker not running"
command -v openssl &>/dev/null || error "openssl required"
command -v unzip &>/dev/null || error "unzip required"

if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    error "Docker Compose not found"
fi

log "Requirements met"

# ─── Step 1: Collect credentials ──────────────────────────────
section "Admin credentials"

read -rp "Admin username: " ADMIN_USERNAME
[ -z "$ADMIN_USERNAME" ] && error "Username required"
read -rp "Admin email: " ADMIN_EMAIL
[ -z "$ADMIN_EMAIL" ] && error "Email required"
read -rsp "Admin password (min 8 chars): " ADMIN_PASSWORD; echo
[ ${#ADMIN_PASSWORD} -lt 8 ] && error "Password too short"
read -rsp "Confirm password: " ADMIN_PASSWORD2; echo
[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ] && error "Passwords don't match"

# OIDC (optional)
echo ""
read -rp "Authentik OIDC base URL (e.g. https://auth.yourdomain.com) or blank to skip: " OIDC_BASE
SOCIAL_OIDC_ID=""; SOCIAL_OIDC_SECRET=""; SOCIAL_OIDC_URL=""
ENGINE_OIDC_ID=""; ENGINE_OIDC_SECRET=""; ENGINE_OIDC_URL=""
if [ -n "$OIDC_BASE" ]; then
    read -rp "Social app OIDC Client ID: " SOCIAL_OIDC_ID
    read -rsp "Social app OIDC Client Secret: " SOCIAL_OIDC_SECRET; echo
    read -rp "Social app OIDC slug (e.g. myarea): " SOCIAL_OIDC_SLUG
    SOCIAL_OIDC_URL="${OIDC_BASE}/application/o/${SOCIAL_OIDC_SLUG}/.well-known/openid-configuration"
    read -rp "Engine OIDC Client ID: " ENGINE_OIDC_ID
    read -rsp "Engine OIDC Client Secret: " ENGINE_OIDC_SECRET; echo
    read -rp "Engine OIDC slug (e.g. crimewars): " ENGINE_OIDC_SLUG
    ENGINE_OIDC_URL="${OIDC_BASE}/application/o/${ENGINE_OIDC_SLUG}/.well-known/openid-configuration"
fi

log "Credentials collected"

# ─── Step 2: Extract archives ─────────────────────────────────
section "Extracting archives"

for dir in "$SOCIAL_DIR" "$ENGINE_DIR" "$HUB_DIR"; do
    [ -d "$dir" ] && rm -rf "$dir"
done

unzip -q "$SOCIAL_ZIP" && log "Social extracted"
unzip -q "$ENGINE_ZIP" -d "$ENGINE_DIR" && log "Engine extracted"
# Handle nested dir in engine zip
INNER=$(ls "$ENGINE_DIR" 2>/dev/null | head -1)
if [ -n "$INNER" ] && [ -d "$ENGINE_DIR/$INNER" ] && [ ! -f "$ENGINE_DIR/docker-compose.yml" ]; then
    mv "$ENGINE_DIR/$INNER"/* "$ENGINE_DIR/" 2>/dev/null || true
    rm -rf "$ENGINE_DIR/$INNER" 2>/dev/null || true
fi

if [ -f "$HUB_ZIP" ]; then
    unzip -q "$HUB_ZIP" && log "Hub extracted"
else
    warn "Hub zip not found — skipping hub deployment"
    HUB_DIR=""
fi

# ─── Step 3: Generate secrets ─────────────────────────────────
section "Generating secrets"

SECRET_SOCIAL=$(gen_secret)
SECRET_ENGINE=$(gen_secret)
DB_PASS_SOCIAL=$(gen_secret | cut -c1-24)
DB_PASS_ENGINE=$(gen_secret | cut -c1-24)
REDIS_PASS_SOCIAL=$(gen_secret | cut -c1-24)
REDIS_PASS_ENGINE=$(gen_secret | cut -c1-24)
SERVICE_API_KEY=$(gen_secret)
log "Secrets generated"

# ─── Step 4: Write .env files ─────────────────────────────────
section "Writing .env files"

cat > "$SOCIAL_DIR/.env" << ENV
FLASK_ENV=production
SECRET_KEY=${SECRET_SOCIAL}
WTF_CSRF_SECRET_KEY=${SECRET_SOCIAL}
POSTGRES_DB=myarea_social
POSTGRES_USER=myarea
POSTGRES_PASSWORD=${DB_PASS_SOCIAL}
REDIS_PASSWORD=${REDIS_PASS_SOCIAL}
HTTP_PORT=${SOCIAL_PORT}
MAX_UPLOAD_MB=10
TOP_FRIENDS_COUNT=8
MAX_CUSTOM_CSS_BYTES=10000
SERVICE_API_KEY=${SERVICE_API_KEY}
GAME_ENGINE_URL=http://myarea_games_web:5000
PREFERRED_URL_SCHEME=https
OIDC_CLIENT_ID=${SOCIAL_OIDC_ID}
OIDC_CLIENT_SECRET=${SOCIAL_OIDC_SECRET}
OIDC_DISCOVERY_URL=${SOCIAL_OIDC_URL}
OIDC_REDIRECT_URI=https://myarea.wrds361.com/auth/oidc/callback
ENV

cat > "$ENGINE_DIR/.env" << ENV
FLASK_ENV=production
SECRET_KEY=${SECRET_ENGINE}
WTF_CSRF_SECRET_KEY=${SECRET_ENGINE}
POSTGRES_DB=myarea
POSTGRES_USER=myarea
POSTGRES_PASSWORD=${DB_PASS_ENGINE}
REDIS_PASSWORD=${REDIS_PASS_ENGINE}
HTTP_PORT=${ENGINE_PORT}
HTTPS_PORT=8922
MAX_UPLOAD_MB=5
UPLOAD_FOLDER=/app/uploads
ENERGY_REGEN_SECONDS=300
STAMINA_REGEN_SECONDS=180
DAILY_RESET_HOUR=0
BASE_MAX_ENERGY=100
BASE_MAX_STAMINA=50
BASE_MAX_HEALTH=100
SERVICE_API_KEY=${SERVICE_API_KEY}
SOCIAL_APP_URL=http://myarea_social_web:5000
PREFERRED_URL_SCHEME=https
OIDC_CLIENT_ID=${ENGINE_OIDC_ID}
OIDC_CLIENT_SECRET=${ENGINE_OIDC_SECRET}
OIDC_DISCOVERY_URL=${ENGINE_OIDC_URL}
OIDC_REDIRECT_URI=https://crimewars.wrds361.com/auth/oidc/callback
ENV

if [ -n "$HUB_DIR" ]; then
    cat > "$HUB_DIR/.env" << ENV
SECRET_KEY=${SERVICE_API_KEY}
SERVICE_API_KEY=${SERVICE_API_KEY}
HTTP_PORT=${HUB_PORT}
CRIMEWARS_URL=https://crimewars.wrds361.com
CRIMEWARS_API_URL=http://myarea_games_web:5000
SOCIAL_APP_URL=https://myarea.wrds361.com
ENV
fi

log ".env files written"

# ─── Step 5: Fix nginx configs ────────────────────────────────
section "Patching nginx configs"

for conf in "$SOCIAL_DIR/nginx/conf.d/myarea.conf" "$ENGINE_DIR/nginx/conf.d/myarea.conf"; do
    if [ -f "$conf" ] && ! grep -q "resolver" "$conf"; then
        sed -i 's/    location \/ {/    resolver 127.0.0.11 valid=10s;\n\n    location \/ {/' "$conf"
        log "Added resolver to $conf"
    fi
done

# ─── Step 6: Shared network ───────────────────────────────────
section "Shared Docker network"

docker network inspect "$SHARED_NETWORK" > /dev/null 2>&1 || \
    (docker network create "$SHARED_NETWORK" && log "Created $SHARED_NETWORK")
log "Shared network ready"

# ─── Step 7: Deploy Social app ────────────────────────────────
section "Deploying Social app"

cd "$SOCIAL_DIR"
$COMPOSE build --quiet && log "Social image built"
$COMPOSE up -d
wait_healthy "myarea_social_db" "Social PostgreSQL"
sleep 5

# Create tables
$COMPOSE exec -T web python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('Social tables created')
" && log "Social tables created"

# Stamp migrations
$COMPOSE exec -T web flask db init 2>/dev/null || true
$COMPOSE exec -T web flask db stamp head 2>/dev/null || true

# Connect to shared network
docker network connect "$SHARED_NETWORK" myarea_social_web 2>/dev/null || true
docker network connect "$SHARED_NETWORK" myarea_social_celery 2>/dev/null || true

# Create admin
$COMPOSE exec -T web python -c "
from app import create_app, db
from app.models import User, Profile
app = create_app()
with app.app_context():
    u = User.query.filter_by(email='${ADMIN_EMAIL}').first()
    if u:
        u.is_admin = True
        u.set_password('${ADMIN_PASSWORD}')
        if not u.profile:
            from slugify import slugify
            p = Profile(user_id=u.id, slug=slugify('${ADMIN_USERNAME}'), display_name='${ADMIN_USERNAME}')
            db.session.add(p)
        db.session.commit()
        print('Social admin updated')
    else:
        u = User(username='${ADMIN_USERNAME}', email='${ADMIN_EMAIL}', is_admin=True)
        u.set_password('${ADMIN_PASSWORD}')
        db.session.add(u)
        db.session.flush()
        from slugify import slugify
        p = Profile(user_id=u.id, slug=slugify('${ADMIN_USERNAME}'), display_name='${ADMIN_USERNAME}')
        db.session.add(p)
        db.session.commit()
        print('Social admin created')
" && log "Social admin ready"

$COMPOSE restart nginx
cd ..

# ─── Step 8: Deploy Game Engine ───────────────────────────────
section "Deploying Crime Wars engine"

cd "$ENGINE_DIR"
$COMPOSE build --quiet && log "Engine image built"
$COMPOSE up -d
wait_healthy "myarea_db" "Engine PostgreSQL"
sleep 5

# Create tables
$COMPOSE exec -T web python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('Engine tables created')
" && log "Engine tables created"

# Stamp + seed
$COMPOSE exec -T web flask db init 2>/dev/null || true
$COMPOSE exec -T web flask db stamp head 2>/dev/null || true
$COMPOSE exec -T web flask seed-db 2>/dev/null && log "Engine seeded" || warn "Seed had issues — run manually later"

# Connect to shared network
docker network connect "$SHARED_NETWORK" myarea_games_web 2>/dev/null || true
docker network connect "$SHARED_NETWORK" myarea_games_celery 2>/dev/null || true

# Create admin
$COMPOSE exec -T web python -c "
from app import create_app, db
from app.models import User, Player
app = create_app()
with app.app_context():
    u = User.query.filter_by(email='${ADMIN_EMAIL}').first()
    if u:
        u.is_admin = True
        u.set_password('${ADMIN_PASSWORD}')
        if not u.player:
            from slugify import slugify
            p = Player(user_id=u.id, slug=slugify('${ADMIN_USERNAME}'), display_name='${ADMIN_USERNAME}',
                       cash=app.config['NEW_PLAYER_CASH'], energy=app.config['NEW_PLAYER_ENERGY'],
                       stamina=app.config['NEW_PLAYER_STAMINA'], health=app.config['NEW_PLAYER_HEALTH'])
            db.session.add(p)
        db.session.commit()
        print('Engine admin updated')
    else:
        u = User(username='${ADMIN_USERNAME}', email='${ADMIN_EMAIL}', is_admin=True)
        u.set_password('${ADMIN_PASSWORD}')
        db.session.add(u)
        db.session.flush()
        from slugify import slugify
        p = Player(user_id=u.id, slug=slugify('${ADMIN_USERNAME}'), display_name='${ADMIN_USERNAME}',
                   cash=app.config['NEW_PLAYER_CASH'], energy=app.config['NEW_PLAYER_ENERGY'],
                   stamina=app.config['NEW_PLAYER_STAMINA'], health=app.config['NEW_PLAYER_HEALTH'])
        db.session.add(p)
        db.session.commit()
        print('Engine admin created')
" && log "Engine admin ready"

$COMPOSE restart nginx
cd ..

# ─── Step 9: Deploy Hub (optional) ────────────────────────────
if [ -n "$HUB_DIR" ]; then
    section "Deploying Games Hub"
    cd "$HUB_DIR"
    $COMPOSE build --quiet && log "Hub image built"
    $COMPOSE up -d
    docker network connect "$SHARED_NETWORK" myarea_hub_web 2>/dev/null || true
    log "Hub deployed"
    cd ..
fi

# ─── Step 10: Verify cross-app connection ─────────────────────
section "Verifying cross-app connection"
sleep 5

ENGINE_CODE=$(docker exec myarea_social_web \
    curl -sf -o /dev/null -w "%{http_code}" \
    -H "X-Service-Key: ${SERVICE_API_KEY}" \
    "http://myarea_games_web:5000/api/v1/leaderboard" 2>/dev/null || echo "000")

[ "$ENGINE_CODE" = "200" ] && log "Social → Engine: connected" || warn "Social → Engine: got $ENGINE_CODE"

# ─── Step 11: Save credentials ────────────────────────────────
CREDS_FILE="myarea_credentials_$(date +%Y%m%d).txt"
cat > "$CREDS_FILE" << CREDS
MyArea Deployment — $(date)
═══════════════════════════════════════

URLS
────
Social:      http://localhost:${SOCIAL_PORT}  (https://myarea.wrds361.com)
Crime Wars:  http://localhost:${ENGINE_PORT}  (https://crimewars.wrds361.com)
Games Hub:   http://localhost:${HUB_PORT}     (https://myareagames.wrds361.com)

ADMIN LOGIN (both apps)
────────────────────────
Username:  ${ADMIN_USERNAME}
Email:     ${ADMIN_EMAIL}
Password:  ${ADMIN_PASSWORD}

SERVICE API KEY
───────────────
${SERVICE_API_KEY}

SOCIAL DB:  myarea_social / myarea / ${DB_PASS_SOCIAL}
ENGINE DB:  myarea / myarea / ${DB_PASS_ENGINE}
SOCIAL REDIS: ${REDIS_PASS_SOCIAL}
ENGINE REDIS: ${REDIS_PASS_ENGINE}

MANAGE
───────
Social:  cd ${SOCIAL_DIR} && docker compose [up/down/logs]
Engine:  cd ${ENGINE_DIR} && docker compose [up/down/logs]
Hub:     cd ${HUB_DIR} && docker compose [up/down/logs]

NOTE: After docker compose down + up, restart nginx:
  docker compose restart nginx
CREDS
chmod 600 "$CREDS_FILE"

# ─── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  MyArea deployed!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Social:     http://localhost:${SOCIAL_PORT}"
echo -e "  Crime Wars: http://localhost:${ENGINE_PORT}"
[ -n "$HUB_DIR" ] && echo -e "  Games Hub:  http://localhost:${HUB_PORT}"
echo ""
echo -e "  Credentials saved to: ${CREDS_FILE}"
echo ""
