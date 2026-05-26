#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# MyArea — New Game Scaffold Script
#
# Creates a new game engine instance from the Crime Wars template.
# Each game gets its own Docker stack, port, domain, and theme.
#
# Usage:
#   chmod +x new_game.sh
#   ./new_game.sh
#
# What it does:
#   1. Asks for game name, domain, port, accent color
#   2. Copies the Crime Wars engine as the base
#   3. Updates all container names, ports, and configs
#   4. Creates custom seed data for the new game's theme
#   5. Writes .env with new secrets
#   6. Builds and starts the new game
#   7. Creates tables, seeds data, creates admin
#   8. Connects to shared network
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${NC}"; }
error()   { echo -e "${RED}❌ $*${NC}"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

gen_secret() { openssl rand -hex 32; }

# ─── Require Crime Wars as the base template ──────────────────
BASE_DIR="myarea_engine"
[ ! -d "$BASE_DIR" ] && error "Cannot find '$BASE_DIR' directory. Run this from the same folder as your deployed apps."

SHARED_NETWORK="myarea_shared_net"

# ─── Collect game info ────────────────────────────────────────
section "New Game Setup"

echo "Available game presets:"
echo "  1) Vampire Wars    — blood, turning victims, clans"
echo "  2) Coke Wars       — drug trade, supply chains, cartels"
echo "  3) Street Wars     — gang territory, drive-bys, blocks"
echo "  4) Spy Wars        — espionage, missions, agencies"
echo "  5) Custom          — blank slate, you define everything"
echo ""
read -rp "Choose preset (1-5): " PRESET

case $PRESET in
    1) GAME_NAME="Vampire Wars"; GAME_SLUG="vampirewars"; ACCENT_COLOR="#7c3aed"; ICON="bi-droplet-fill"
       JOB_THEME="hunt"; GANG_THEME="coven" ;;
    2) GAME_NAME="Coke Wars";    GAME_SLUG="cokewars";    ACCENT_COLOR="#22c55e"; ICON="bi-capsule"
       JOB_THEME="deal"; GANG_THEME="cartel" ;;
    3) GAME_NAME="Street Wars";  GAME_SLUG="streetwars";  ACCENT_COLOR="#f97316"; ICON="bi-shield-fill"
       JOB_THEME="hustle"; GANG_THEME="crew" ;;
    4) GAME_NAME="Spy Wars";     GAME_SLUG="spywars";     ACCENT_COLOR="#0ea5e9"; ICON="bi-eye-fill"
       JOB_THEME="mission"; GANG_THEME="agency" ;;
    5)
       read -rp "Game name (e.g. 'Dragon Wars'): " GAME_NAME
       read -rp "URL slug (e.g. 'dragonwars', no spaces): " GAME_SLUG
       read -rp "Accent color (hex, e.g. #e63946): " ACCENT_COLOR
       ICON="bi-controller"; JOB_THEME="quest"; GANG_THEME="guild" ;;
    *) error "Invalid choice" ;;
esac

read -rp "Domain (e.g. ${GAME_SLUG}.wrds361.com): " GAME_DOMAIN
[ -z "$GAME_DOMAIN" ] && GAME_DOMAIN="${GAME_SLUG}.wrds361.com"

read -rp "HTTP port (check 'docker ps' first, must be unused): " GAME_PORT
[ -z "$GAME_PORT" ] && error "Port required"

GAME_DIR="myarea_${GAME_SLUG}"
[ -d "$GAME_DIR" ] && error "Directory '$GAME_DIR' already exists"

# Get SERVICE_API_KEY from existing engine
SERVICE_API_KEY=$(grep "^SERVICE_API_KEY=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 || gen_secret)
ADMIN_EMAIL=$(grep "^# Admin" "$BASE_DIR/.env" 2>/dev/null | head -1 || echo "")

read -rp "Admin email for this game: " ADMIN_EMAIL
read -rp "Admin username: " ADMIN_USERNAME
read -rsp "Admin password: " ADMIN_PASSWORD; echo

log "Creating $GAME_NAME..."

# ─── Copy base engine ─────────────────────────────────────────
section "Copying base engine"

cp -r "$BASE_DIR" "$GAME_DIR"

# Remove old migrations and pycache
rm -rf "$GAME_DIR/app/migrations" 2>/dev/null || true
find "$GAME_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

log "Base engine copied to $GAME_DIR"

# ─── Update container names and ports ─────────────────────────
section "Updating configuration"

SAFE_SLUG="${GAME_SLUG//-/_}"

python3 << PYEOF
import re

# Update docker-compose.yml
with open('${GAME_DIR}/docker-compose.yml', 'r') as f:
    content = f.read()

# Replace container names
content = content.replace('myarea_games_web',    'myarea_${SAFE_SLUG}_web')
content = content.replace('myarea_games_celery', 'myarea_${SAFE_SLUG}_celery')
content = content.replace('myarea_games_beat',   'myarea_${SAFE_SLUG}_beat')
content = content.replace('myarea_games_nginx',  'myarea_${SAFE_SLUG}_nginx')
content = content.replace('myarea_db',           'myarea_${SAFE_SLUG}_db')
content = content.replace('myarea_redis',        'myarea_${SAFE_SLUG}_redis')
content = content.replace('myarea_net',          'myarea_${SAFE_SLUG}_net')

# Update image names
content = content.replace('myarea_engine-web',          'myarea_${SAFE_SLUG}-web')
content = content.replace('myarea_engine-celery_worker','myarea_${SAFE_SLUG}-celery_worker')
content = content.replace('myarea_engine-celery_beat',  'myarea_${SAFE_SLUG}-celery_beat')

# Update ports
content = re.sub(r'"\$\{HTTP_PORT:-8921\}:80"',  '"\${HTTP_PORT:-${GAME_PORT}}:80"', content)
content = re.sub(r'"\$\{HTTPS_PORT:-8922\}:443"', '"\${HTTPS_PORT:-$((${GAME_PORT}+1))}:443"', content)

# Update DB name
content = content.replace('POSTGRES_DB:-myarea}', 'POSTGRES_DB:-myarea_${SAFE_SLUG}}')

# Update network name in networks section
content = content.replace(
    'networks:\n  myarea_net:\n    driver: bridge',
    'networks:\n  myarea_${SAFE_SLUG}_net:\n    driver: bridge'
)

with open('${GAME_DIR}/docker-compose.yml', 'w') as f:
    f.write(content)
print('docker-compose.yml updated')

# Update nginx config
import os
nginx_conf = '${GAME_DIR}/nginx/conf.d/myarea.conf'
if os.path.exists(nginx_conf):
    with open(nginx_conf, 'r') as f:
        nginx = f.read()
    nginx = nginx.replace('myarea_games_app', 'myarea_${SAFE_SLUG}_app')
    nginx = nginx.replace('crimewars.wrds361.com', '${GAME_DOMAIN}')
    nginx = nginx.replace('upstream myarea_games_app', 'upstream myarea_${SAFE_SLUG}_app')
    if 'resolver' not in nginx:
        nginx = nginx.replace('    location / {', '    resolver 127.0.0.11 valid=10s;\n\n    location / {')
    with open(nginx_conf, 'w') as f:
        f.write(nginx)
    print('nginx config updated')

# Update nginx locations conf if exists
locations_conf = '${GAME_DIR}/nginx/conf.d/myarea_locations.conf'
if os.path.exists(locations_conf):
    with open(locations_conf, 'r') as f:
        loc = f.read()
    loc = loc.replace('myarea_games_app', 'myarea_${SAFE_SLUG}_app')
    with open(locations_conf, 'w') as f:
        f.write(loc)
    print('locations config updated')
PYEOF

log "Container names and ports updated"

# ─── Write .env ───────────────────────────────────────────────
section "Writing .env"

SECRET_KEY=$(gen_secret)
DB_PASS=$(gen_secret | cut -c1-24)
REDIS_PASS=$(gen_secret | cut -c1-24)

cat > "$GAME_DIR/.env" << ENV
FLASK_ENV=production
SECRET_KEY=${SECRET_KEY}
WTF_CSRF_SECRET_KEY=${SECRET_KEY}
POSTGRES_DB=myarea_${SAFE_SLUG}
POSTGRES_USER=myarea
POSTGRES_PASSWORD=${DB_PASS}
REDIS_PASSWORD=${REDIS_PASS}
HTTP_PORT=${GAME_PORT}
HTTPS_PORT=$((GAME_PORT+1))
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
OIDC_CLIENT_ID=
OIDC_CLIENT_SECRET=
OIDC_DISCOVERY_URL=
OIDC_REDIRECT_URI=https://${GAME_DOMAIN}/auth/oidc/callback
ENV

log ".env written"

# ─── Update theme accent color ────────────────────────────────
section "Applying theme"

python3 << PYEOF
with open('${GAME_DIR}/app/static/css/myarea.css', 'r') as f:
    css = f.read()
# Replace accent color
css = css.replace('--ma-accent:      #e63946;', '--ma-accent:      ${ACCENT_COLOR};')
with open('${GAME_DIR}/app/static/css/myarea.css', 'w') as f:
    f.write(css)
print('Theme accent color updated to ${ACCENT_COLOR}')
PYEOF

log "Theme applied"

# ─── Create game-specific seed data ───────────────────────────
section "Creating seed data"

cat > "$GAME_DIR/app/game_seed.py" << PYEOF
"""
${GAME_NAME} — Custom seed data
Replace the default Crime Wars jobs/properties/items with theme-appropriate ones.
Run with: flask seed-game
"""

JOBS = [
    # (name, category, energy, cash_min, cash_max, xp, crime_pts, success_rate, jail_secs, min_level)
    # Add your game-specific jobs here
    # Example for Vampire Wars:
    # ("Feed on Victim", "hunt", 2, 50, 200, 5, 1, 0.90, 60, 1),
    # ("Turn a Human", "hunt", 10, 500, 2000, 30, 10, 0.60, 300, 10),
]

PROPERTIES = [
    # (name, category, buy_price, sell_price, income_per_hour, min_level)
    # Example:
    # ("Blood Bank", "criminal", 10000, 7000, 150, 1),
]

ITEMS = [
    # (name, category, rarity, buy_price, sell_price, atk, def)
    # Example:
    # ("Wooden Stake", "weapon", "common", 500, 250, 5, 0),
]
PYEOF

log "Seed template created at $GAME_DIR/app/game_seed.py"
warn "Edit $GAME_DIR/app/game_seed.py to add ${GAME_NAME}-specific jobs, properties, and items"

# ─── Build and start ──────────────────────────────────────────
section "Building and starting $GAME_NAME"

cd "$GAME_DIR"

if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
else
    COMPOSE="docker-compose"
fi

$COMPOSE build --quiet && log "Image built"
$COMPOSE up -d && log "Containers started"

# Wait for DB
echo -n "   Waiting for database"
for i in $(seq 1 40); do
    docker inspect --format='{{.State.Health.Status}}' "myarea_${SAFE_SLUG}_db" 2>/dev/null | grep -q "healthy" && break
    sleep 3; echo -n "."
done
echo " ready!"

sleep 5

# Create tables
$COMPOSE exec -T web python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('Tables created')
" && log "Tables created"

# Stamp migrations
$COMPOSE exec -T web flask db init 2>/dev/null || true
$COMPOSE exec -T web flask db stamp head 2>/dev/null || true

# Seed default game data
$COMPOSE exec -T web flask seed-db 2>/dev/null && log "Default data seeded" || warn "Seed had issues"

# Create admin
$COMPOSE exec -T web python -c "
from app import create_app, db
from app.models import User, Player
from slugify import slugify
app = create_app()
with app.app_context():
    existing = User.query.filter_by(email='${ADMIN_EMAIL}').first()
    if existing:
        existing.is_admin = True
        existing.set_password('${ADMIN_PASSWORD}')
        db.session.commit()
        print('Admin updated')
    else:
        u = User(username='${ADMIN_USERNAME}', email='${ADMIN_EMAIL}', is_admin=True)
        u.set_password('${ADMIN_PASSWORD}')
        db.session.add(u)
        db.session.flush()
        p = Player(user_id=u.id, slug=slugify('${ADMIN_USERNAME}'),
                   display_name='${ADMIN_USERNAME}',
                   cash=app.config['NEW_PLAYER_CASH'],
                   energy=app.config['NEW_PLAYER_ENERGY'],
                   stamina=app.config['NEW_PLAYER_STAMINA'],
                   health=app.config['NEW_PLAYER_HEALTH'])
        db.session.add(p)
        db.session.commit()
        print('Admin created')
" && log "Admin ready"

# Connect to shared network
docker network connect "$SHARED_NETWORK" "myarea_${SAFE_SLUG}_web" 2>/dev/null || true
docker network connect "$SHARED_NETWORK" "myarea_${SAFE_SLUG}_celery" 2>/dev/null || true

# Restart nginx to pick up correct upstream IP
$COMPOSE restart nginx
log "Nginx restarted"

cd ..

# ─── Update hub game list ─────────────────────────────────────
section "Updating Games Hub"

HUB_INIT="myarea_hub/app/__init__.py"
if [ -f "$HUB_INIT" ]; then
    python3 << PYEOF
with open('${HUB_INIT}', 'r') as f:
    content = f.read()

new_game = '''            {
                "id":      "${GAME_SLUG}",
                "name":    "${GAME_NAME}",
                "tagline": "A new game on the MyArea platform.",
                "url":     "https://${GAME_DOMAIN}",
                "api_url": "http://myarea_${SAFE_SLUG}_web:5000",
                "icon":    "${ICON}",
                "color":   "${ACCENT_COLOR}",
                "players": 0,
                "status":  "live",
            },'''

old = '            # Add more games here as they\'re built:'
new = new_game + '\n            # Add more games here as they\'re built:'

if old in content and new_game not in content:
    content = content.replace(old, new, 1)
    with open('${HUB_INIT}', 'w') as f:
        f.write(content)
    print('Hub updated with ${GAME_NAME}')
else:
    print('Hub already has ${GAME_NAME} or pattern not found — add manually')
PYEOF

    # Restart hub
    cd myarea_hub && $COMPOSE restart web 2>/dev/null && cd .. && log "Hub updated"
else
    warn "Hub not found — add $GAME_NAME manually to myarea_hub/app/__init__.py"
fi

# ─── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ${GAME_NAME} deployed!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  URL:        http://localhost:${GAME_PORT}"
echo -e "  Domain:     https://${GAME_DOMAIN}"
echo -e "  Directory:  ${GAME_DIR}/"
echo -e "  Admin:      ${ADMIN_USERNAME} / (your password)"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Add ${GAME_NAME} to Cloudflare DNS → ${GAME_DOMAIN}"
echo -e "  2. Add Authentik OIDC app for ${GAME_DOMAIN}/auth/oidc/callback"
echo -e "  3. Edit ${GAME_DIR}/app/game_seed.py with theme jobs/items"
echo -e "  4. Run: cd ${GAME_DIR} && docker compose exec web flask seed-db"
echo ""
