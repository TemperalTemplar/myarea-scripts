# MyArea Scripts

Deployment and management scripts for the MyArea platform.

## Scripts

### `deploy_myarea_v2.sh` — Full platform deploy
Deploys the entire MyArea platform from scratch on a new server.

**Requirements:**
- Docker + Docker Compose
- `openssl` and `unzip`
- These zip files in the same folder:
  - `myarea_social_connected.zip`
  - `myarea_engine_connected.zip`
  - `myarea_hub.zip`

**Usage:**
```bash
chmod +x deploy_myarea_v2.sh
./deploy_myarea_v2.sh
```

**What it does:**
1. Checks requirements
2. Asks for admin username, email, password
3. Optionally configures Authentik OIDC
4. Extracts all zips
5. Generates all secrets automatically
6. Writes `.env` files for all three apps
7. Patches nginx configs with DNS resolver fix
8. Creates the `myarea_shared_net` Docker network
9. Builds and starts Social app
10. Creates database tables and stamps migrations
11. Builds and starts Game Engine
12. Creates tables, seeds jobs/properties/items
13. Builds and starts Games Hub
14. Connects all containers to shared network
15. Creates admin accounts on both apps
16. Verifies cross-app API connection
17. Saves all credentials to `myarea_credentials_YYYYMMDD.txt`

---

### `new_game.sh` — Add a new game to the platform
Creates a new game engine instance from the Crime Wars template.

**Requirements:**
- Must be run from the same folder as your deployed apps
- `myarea_engine/` directory must exist (the Crime Wars engine)
- `myarea_shared_net` network must exist

**Usage:**
```bash
chmod +x new_game.sh
./new_game.sh
```

**What it does:**
1. Asks you to pick a preset or custom game
2. Asks for domain, port, admin credentials
3. Copies the engine, renames all containers
4. Applies theme accent color to CSS
5. Writes `.env` with new secrets
6. Builds and starts the new game
7. Creates tables, seeds default data
8. Creates admin account
9. Connects to shared network
10. Adds the game to the Games Hub automatically

**Presets:**
| # | Game | Color |
|---|---|---|
| 1 | Vampire Wars | Purple `#7c3aed` |
| 2 | Coke Wars | Green `#22c55e` |
| 3 | Street Wars | Orange `#f97316` |
| 4 | Spy Wars | Blue `#0ea5e9` |
| 5 | Custom | You choose |

**After running:**
1. Add DNS record in Cloudflare pointing the new domain to your server
2. Create an Authentik OIDC application with redirect URI `https://yourdomain.com/auth/oidc/callback`
3. Add the Client ID, Secret, and Discovery URL to the new game's `.env`
4. Run `docker compose up -d` in the new game directory

---

## Important notes

**After `docker compose down` on any app:**
```bash
docker compose up -d
docker network connect myarea_shared_net <container_name>_web
docker compose restart nginx
```

**The `myarea_shared_net` network must always exist:**
```bash
docker network create myarea_shared_net
```

**All apps share the same `SERVICE_API_KEY`** — this is what allows them to communicate. It's generated once by `deploy_myarea_v2.sh` and must be the same in every app's `.env`.
