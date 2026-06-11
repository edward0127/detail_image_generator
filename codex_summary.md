Done. I added production Docker Compose deployment support and did not start a Rails server.

**Files Changed**
`Dockerfile`, `docker-compose.yml`, `.env.prod.example`, `.gitignore`, `Gemfile.lock`, `README.md`, `config/database.yml`, `config/environments/production.rb`, `app/controllers/application_controller.rb`, `app/services/image_projects/renderer.rb`, `script/deploy.sh`, `script/deploy_production.sh`, `test/controllers/basic_auth_test.rb`.

**Key Changes**
- Docker image now installs Chromium, fontconfig, Noto CJK/emoji fonts, SQLite, jemalloc, and Debian 13’s correct libvips runtime package: `libvips42t64`.
- Added `CHROME_BIN=/usr/bin/chromium` and `BROWSER_PATH=/usr/bin/chromium`.
- Ferrum now includes Docker-safe browser options: `no-sandbox`, `disable-dev-shm-usage`, `disable-gpu`, `hide-scrollbars`.
- Production SQLite now defaults to `/data/production*.sqlite3`.
- Active Storage persists through the Compose volume mounted at `/rails/storage`.
- Added optional env-gated Basic Auth using `ENABLE_BASIC_AUTH=true`, `BASIC_AUTH_USERNAME`, and `BASIC_AUTH_PASSWORD`.
- Added production Compose service:
  - image: `ghcr.io/edward0127/detail_image_generator:latest`
  - container: `detail_image_generator`
  - port: `127.0.0.1:3015:80`
  - volumes: `detail_image_generator_data:/data`, `detail_image_generator_storage:/rails/storage`
  - `shm_size: "1gb"` for Chromium.
- Added TDK-style deploy scripts with `deploy`, `logs`, `status`, `restart`, `prepare`, `migrate`, `down`, plus `pull`, `verify`, `seed`.
- README now documents first setup, redeploy, DNS, example Nginx proxy, SSL via Certbot, and useful server commands.

**Verification Run**
- `bundle lock --add-platform x86_64-linux`
- `bundle exec rails test`: passed, `72 runs, 523 assertions`
- `bundle exec rails zeitwerk:check`: passed
- `bash -n script/deploy.sh script/deploy_production.sh`: passed
- Docker package verification: `ruby:3.3.10-slim` is Debian 13 trixie; corrected `libvips` to `libvips42t64`
- `docker build -t detail_image_generator:test .`: passed
- Container smoke test: non-root `rails` user, writable `/data` and `/rails/storage`, Chromium launches
- Ferrum smoke test inside Docker: passed
- `docker compose -f docker-compose.yml config`: passed with a temporary `.env.prod` copied from the example, then removed

**Manual Server Steps**
```sh
mkdir -p /var/detail_image_generator
git clone git@github.com:edward0127/detail_image_generator.git /var/detail_image_generator
cd /var/detail_image_generator
cp .env.prod.example .env.prod
# edit .env.prod with real values
docker login ghcr.io
./script/deploy.sh deploy
```

Normal redeploy:
```sh
./script/deploy_production.sh --auto-commit "Deploy detail image generator"
```

**Remaining Limitations**
No GHCR push, SSH deployment, live Nginx edit, or Certbot run was performed. `.env.prod` still needs real production secrets on the server.