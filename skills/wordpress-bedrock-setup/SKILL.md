---
name: "wordpress-bedrock-setup"
description: "Professional WordPress orchestration with Bedrock, Composer, and Git tracking"
version: "2.0.0"
author: "Agent Zero"
tags: ["wordpress", "bedrock", "git", "devops", "orchestration", "agent-zero"]
trigger_patterns:
  - "setup bedrock wordpress"
  - "create bedrock site"
  - "wordpress git orchestration"
  - "/wp-bedrock-setup"
  - "setup wordpress project"
---

# WordPress Full-Track Orchestration v2.0

Professional WordPress development workflow using **Bedrock** architecture integrated with **Agent Zero projects**. The entire site (themes, plugins) is tracked in Git at the project root.

## When to Use
- Setting up a new WordPress development environment
- When you need full Git tracking of WordPress code
- Professional, scalable WordPress sites with Composer dependency management
- Multi-container Docker stacks (Nginx, PHP-FPM, MariaDB)

## Architecture Overview

### Project Structure (A0 Project + Bedrock)
```
Project Root/              ← Git repo root, A0 project root
├── .a0proj/               ← A0 config (gitignored)
├── .git/                  ← Git at ROOT
├── web/                   ← Bedrock WordPress
│   ├── app/               ← Custom content (tracked)
│   │   ├── themes/        ← Custom themes
│   │   ├── plugins/       ← Custom/premium plugins
│   │   ├── uploads/       ← Media (gitignored)
│   │   └── mu-plugins/    ← Must-use plugins
│   ├── wp/                ← WordPress core (gitignored)
│   ├── index.php
│   └── wp-config.php
├── config/                ← Bedrock environment configs
│   ├── application.php
│   └── environments/
│       ├── development.php
│       └── staging.php
├── vendor/                ← Composer packages (gitignored)
├── composer.json          ← Dependency definitions
├── composer.lock          ← Locked versions
├── docker-compose.yml     ← Container orchestration
├── Dockerfile             ← PHP-FPM image
├── nginx.conf             ← Nginx configuration
├── .env                   ← Environment variables (gitignored)
├── .env.example           ← Template for .env
└── .gitignore
```

### Key Principles
1. **Git at project root** - Not in a subdirectory
2. **A0 native Git integration** - Set `git_url` in project.json
3. **Composer for dependencies** - Plugins via wpackagist
4. **Docker for isolation** - Consistent environments

---

## Procedures

### Procedure 1: Create New WordPress Project

#### Step 1: Create A0 Project with Git URL
In Agent Zero UI or via API, create project with:
```json
{
  "title": "My WordPress Site",
  "git_url": "https://github.com/user/repo",
  "description": "WordPress site with Bedrock"
}
```

Or update existing project.json:
```bash
cd /a0/usr/projects/<project>/
# Edit .a0proj/project.json to add git_url
```

#### Step 2: Initialize Bedrock at Project Root
```bash
cd /a0/usr/projects/<project>/

# Create Bedrock structure
composer create-project roots/bedrock temp-bedrock
mv temp-bedrock/* .
mv temp-bedrock/.* . 2>/dev/null
rm -rf temp-bedrock

# Initialize Git if not already
git init
git remote add origin https://<token>@github.com/user/repo.git
```

#### Step 3: Create Docker Configuration

**docker-compose.yml:**
```yaml
name: wordpress-dev

services:
  nginx:
    image: nginx:1.25-alpine
    container_name: wp-dev-nginx
    restart: unless-stopped
    ports:
      - "127.0.0.1:8086:80"
    volumes:
      - .:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - wordpress
    networks:
      - wp-net

  wordpress:
    build: .
    container_name: wp-dev-app
    restart: unless-stopped
    volumes:
      - .:/var/www/html
    depends_on:
      mariadb:
        condition: service_healthy
    networks:
      - wp-net
      - agent-zero_default  # For A0 container access

  mariadb:
    image: mariadb:10.11
    container_name: wp-dev-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: wordpress_dev
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: wordpress
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - wp-net

networks:
  wp-net:
  agent-zero_default:
    external: true

volumes:
  db_data:
    name: wp-dev-db-data
```

**Dockerfile:**
```dockerfile
FROM php:8.2-fpm-alpine

RUN apk add --no-cache \
    libpng-dev libjpeg-turbo-dev freetype-dev \
    libzip-dev icu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd mysqli pdo pdo_mysql zip intl opcache

# Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

WORKDIR /var/www/html
```

**nginx.conf:**
```nginx
server {
    listen 80;
    server_name localhost;
    root /var/www/html/web;
    index index.php index.html;

    # Buffer settings for large headers/cookies
    client_header_buffer_size 64k;
    large_client_header_buffers 4 64k;
    client_max_body_size 100M;

    fastcgi_buffer_size 128k;
    fastcgi_buffers 4 256k;
    fastcgi_busy_buffers_size 256k;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires max;
        log_not_found off;
    }
}
```

#### Step 4: Configure Environment

**.env:**
```bash
DB_NAME='wordpress_dev'
DB_USER='wordpress'
DB_PASSWORD='wordpress'
DB_HOST='mariadb'

WP_ENV='development'
WP_HOME='https://your-domain.com:9002'
WP_SITEURL="${WP_HOME}/wp"

# Generate from https://roots.io/salts.html
AUTH_KEY='...'
SECURE_AUTH_KEY='...'
# etc.
```

#### Step 5: Create .gitignore
```gitignore
# A0 Project (never track)
.a0proj/

# Bedrock
web/wp/
vendor/
.env
.env.*
!.env.example

# Uploads
web/app/uploads/*
!web/app/uploads/.gitkeep

# Cache
web/app/cache/*

# Dependencies
node_modules/

# IDE
.vscode/
.idea/

```

#### Step 6: Start Containers (from VPS)
```bash
# SSH to VPS, navigate to mounted project path
cd /path/to/mounted/project/
docker compose up -d --build

# Install WordPress
docker exec wp-dev-app wp core install \
  --url="https://your-domain.com:9002" \
  --title="Site Title" \
  --admin_user=admin \
  --admin_password=admin123 \
  --admin_email=admin@example.com \
  --path=/var/www/html/web/wp \
  --allow-root
```

---

### Procedure 2: Add Plugins via Composer

```bash
cd /a0/usr/projects/<project>/

# Add plugin from wpackagist
composer require wpackagist-plugin/advanced-custom-fields
composer require wpackagist-plugin/wordpress-seo
composer require wpackagist-plugin/contact-form-7

# Run quality gate before committing
composer lint:fix
composer lint
composer analyse

# Commit and push
git add composer.json composer.lock
git commit -m "feat: add ACF, Yoast SEO, CF7 plugins"
git push
```

---

### Procedure 3: Migrate Existing WordPress

#### Step 1: Export from Source
```bash
# Export database
wp db export /tmp/export.sql --path=/path/to/wordpress --allow-root

# Archive uploads
tar -czf /tmp/uploads.tar.gz -C /path/to/wordpress/wp-content uploads
```

#### Step 2: Import to Bedrock
```bash
# Import database
docker exec wp-dev-app wp db import /tmp/export.sql \
  --path=/var/www/html/web/wp --allow-root

# Extract uploads to Bedrock location
tar -xzf uploads.tar.gz -C /project/web/app/

# Fix permissions
docker exec wp-dev-app chown -R www-data:www-data /var/www/html/web/app/uploads
```

#### Step 3: Search-Replace URLs
```bash
# Replace old URL with new
docker exec wp-dev-app wp search-replace \
  'https://old-site.com' 'https://new-site.com:9002' \
  --all-tables --path=/var/www/html/web/wp --allow-root

# Replace wp-content paths for Bedrock
docker exec wp-dev-app wp search-replace \
  '/wp-content/' '/app/' \
  --all-tables --path=/var/www/html/web/wp --allow-root
```

---

### Procedure 4: Development Workflow

> **CRITICAL:** Always run the quality gate before pushing. GitHub Actions runs
> `composer lint`, `composer analyse`, and `composer test` on every push.
> Pushing without local checks will cause CI failures.

#### Step 1: Make Changes
```bash
# All operations from project root
cd /a0/usr/projects/<project>/

# Pull latest first
git pull origin <branch>

# ... make your code changes ...
```

#### Step 2: Quality Gate (REQUIRED before push)
```bash
cd /a0/usr/projects/<project>/

# Auto-fix code style issues
composer lint:fix

# Verify lint passes (this is what CI runs)
composer lint

# Run static analysis
composer analyse

# Run tests
composer test
```

> If any step fails, fix the issues before proceeding. Do NOT push with failures.

#### Step 3: Commit and Push
```bash
# Stage all changes (including any lint:fix auto-corrections)
git add .
git commit -m "feat: description of changes"
git push origin <branch>
```

#### Step 4: Verify CI (optional)
```bash
# Check GitHub Actions status via API
curl -s -H "Authorization: token <GITHUB_PAT>"   "https://api.github.com/repos/<owner>/<repo>/actions/runs?per_page=3" |   python3 -c "import sys,json; runs=json.load(sys.stdin).get('workflow_runs',[]); [print(f'{r["name"]}: {r["conclusion"] or r["status"]}') for r in runs]"
```

#### Step 5: Post-deploy (if needed)
```bash
# Restart containers after config changes
ssh user@vps 'cd /path/to/project && docker compose restart'
```

---

---

### Procedure 5: Connect/Reconnect to Existing WordPress Containers

Use this when a WordPress dev environment already exists in Docker containers on the VPS, but the Agent Zero instance has changed (different A0 container, rebuilt container, or different project path). The bind mounts will point to the old A0 instance path and need updating.

> **Note:** The `name: wordpress-dev` field in `docker-compose.yml` ensures Docker Compose uses a fixed project name regardless of the folder it's launched from. This means containers are always named `wp-dev-*` and the named volume `wp-dev-db-data` persists across recreations.

#### Step 1: Detect Current A0 Host Path
From inside the A0 container, determine the host-side path by inspecting the A0 container's own mount:
```bash
sshpass -p '<SSH_PASSWORD>' ssh -o StrictHostKeyChecking=no <SSH_USER>@<VPS_HOST> \
  "docker inspect <a0-container-name> --format '{{range .Mounts}}{{if eq .Destination \"/a0\"}}{{.Source}}{{end}}{{end}}'"
```
This returns the host path, e.g. `/home/user/agent-zero/testing`.

#### Step 2: Check Current Container Volume Mappings
Inspect the WordPress containers to see where they're currently mounted:
```bash
ssh <VPS> "docker inspect wp-dev-app --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'"
```

#### Step 3: Compare Paths
The expected host path for the project is:
```
<A0_HOST_PATH>/usr/projects/<project_name>/
```
If the container mount source differs from this, the containers need to be recreated.

#### Step 4: Stop Old Containers
```bash
ssh <VPS> "docker rm -f wp-dev-nginx wp-dev-app wp-dev-db 2>/dev/null"
```
> **Note:** The named DB volume `wp-dev-db-data` persists independently — your database data is safe.

#### Step 5: Recreate Containers from Correct Path
```bash
ssh <VPS> "cd <A0_HOST_PATH>/usr/projects/<project_name> && docker compose up -d --build"
```

#### Step 6: Verify
```bash
ssh <VPS> "docker inspect wp-dev-app --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'"
```
Confirm the mount source now matches the expected `<A0_HOST_PATH>/usr/projects/<project_name>` path.

#### Step 7: Install Composer Dependencies
After reconnecting containers to a new path, `vendor/` and `web/wp/` will be empty since they're gitignored. You must run `composer install` to restore WordPress core and all PHP dependencies.

First, ensure the target directories are writable from the bind mount. From inside the A0 container:
```bash
cd /a0/usr/projects/<project>/
mkdir -p vendor web/wp
chmod 777 vendor web/wp
```

Then run composer install inside the WordPress container:
```bash
ssh <VPS> "docker exec wp-dev-app composer install --working-dir=/var/www/html --no-interaction"
```

If `vendor/autoload.php` is missing after install (e.g., due to timeout), generate it:
```bash
ssh <VPS> "docker exec wp-dev-app composer dump-autoload --working-dir=/var/www/html --no-interaction"
```

Verify:
```bash
ssh <VPS> "docker exec wp-dev-app ls /var/www/html/vendor/autoload.php /var/www/html/web/wp/wp-blog-header.php"
```

#### Step 8: Ensure .env File Exists
The `.env` file is gitignored and won't be present in a fresh clone. Without it, WordPress can't connect to the database.

Check if `.env` exists:
```bash
ls /a0/usr/projects/<project>/.env
```

If missing, either:
- Copy from the old project path (if still available on VPS)
- Create from `.env.example` with the correct values:
```bash
cp /a0/usr/projects/<project>/.env.example /a0/usr/projects/<project>/.env
# Then edit .env with correct DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, WP_HOME, WP_SITEURL, and security keys
```

After creating `.env`, restart the containers:
```bash
ssh <VPS> "cd <A0_HOST_PATH>/usr/projects/<project_name> && docker compose restart"
```

Verify the database connection:
```bash
ssh <VPS> "docker exec wp-dev-app wp option get blogname --path=/var/www/html/web/wp --allow-root"
```

## VPS Nginx Proxy Configuration

On the host VPS, configure nginx to proxy to Docker:

```nginx
server {
    listen 9002 ssl;
    server_name your-domain.com;

    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    client_header_buffer_size 128k;
    large_client_header_buffers 4 128k;

    location / {
        proxy_pass http://127.0.0.1:8086;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port 9002;
    }
}
```

---

## Tips

- **Use WP-CLI** for database operations inside container
- **Private repos only** for full-site tracking
- **Keep uploads gitignored** - use Docker volume or sync separately
- **Disable WP_DEBUG_DISPLAY** in development.php for clean output
- **agent-zero_default network** allows A0 containers to access WordPress

---

### Procedure 6: Full Database Sync (Dev → Prod)

Sync the entire dev database to production with automatic URL replacement and cache flushing.

#### When to Use
- Deploying a complete dev environment to production
- Resetting prod to match dev state (content, settings, everything)
- Initial production deployment from a dev build

#### Prerequisites
- Dev containers (`wp-dev-app`, `wp-dev-db`) running and accessible via Docker
- Prod container (`wp-prod-app`) running on VPS, accessible via SSH
- SSH credentials configured (env vars or passed as arguments)
- `sshpass` installed in the executing environment

> **⚠️ WARNING:** This overwrites the **entire** production database. A backup is created automatically, but ensure you understand the implications.

#### Step 1: Dry Run (Recommended First)
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-db-full.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --dry-run
```
This shows what would happen without making any changes. URLs are auto-detected.

#### Step 2: Execute Full Sync
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-db-full.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --confirm
```

#### Step 3: Verify
```bash
sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no $SSH_USERNAME@$SSH_HOSTNAME \
  "docker exec wp-prod-app wp option get blogname --path=/var/www/html/web/wp --allow-root"
```

#### Optional: Override Auto-detected URLs
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-db-full.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --dev-url=https://dev.example.com:9002 \
  --prod-url=https://prod.example.com \
  --confirm
```

#### Script Features
- Auto-detects dev URL from project `.env` (`WP_HOME`)
- Auto-detects prod URL via `wp option get home` on prod
- Creates automatic backup of prod DB before import
- Performs `wp search-replace` across all tables
- Flushes object cache, rewrite rules, and transients
- Cleans up temporary files after completion

---

### Procedure 7: Selective Content Sync

Sync specific posts or pages by ID from dev to prod, with URL replacement in content.

#### When to Use
- Deploying specific page/post content changes to production
- Syncing a landing page or blog post after editing in dev
- Pushing individual content updates without affecting the full database

#### Prerequisites
- Same as Procedure 6 (dev/prod containers, SSH access)
- Know the post/page IDs to sync (find via WP admin or `wp post list`)

> **⚠️ WARNING:** Existing posts with matching IDs on prod will be overwritten. Posts not found on prod will be created (possibly with a different ID).

#### Step 1: Find Post IDs
```bash
# List pages on dev
docker exec wp-dev-app wp post list --post_type=page --fields=ID,post_title,post_status \
  --path=/var/www/html/web/wp --allow-root

# List posts on dev
docker exec wp-dev-app wp post list --post_type=post --fields=ID,post_title,post_status \
  --path=/var/www/html/web/wp --allow-root
```

#### Step 2: Dry Run
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-content-selective.sh \
  --ids=442,524 \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --dry-run
```

#### Step 3: Execute Sync
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-content-selective.sh \
  --ids=442,524 \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD
```

#### Script Features
- Exports post title, status, type, slug, and full content
- Replaces dev URLs with prod URLs in post content
- Updates existing posts on prod or creates new ones
- Transfers content via temp files to avoid shell escaping issues
- Shows per-post summary with content length and URL replacement status

---

### Procedure 8: Media/Uploads Sync

Sync media upload files between dev and prod using rsync over SSH.

#### When to Use
- Deploying uploaded media (images, documents) from dev to prod
- Pulling prod media to dev for local development
- Keeping uploads in sync after content changes

#### Prerequisites
- SSH access to the VPS (same credentials as other sync procedures)
- `rsync` and `sshpass` installed in the executing environment
- Dev uploads directory accessible at `<project>/web/app/uploads/`
- Prod uploads at `<prod-server-path>/web/app/uploads/`

#### Step 1: Dry Run (Dev → Prod)
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-uploads.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --dry-run
```

#### Step 2: Execute Sync (Dev → Prod)
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-uploads.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD
```

#### Step 3: Pull Prod Media to Dev (Reverse Direction)
```bash
bash /a0/skills/wordpress-bedrock-setup/scripts/sync-uploads.sh \
  --ssh-host=$SSH_HOSTNAME --ssh-user=$SSH_USERNAME --ssh-pass=$SSH_PASSWORD \
  --direction=prod-to-dev
```

#### Script Features
- Uses rsync for efficient incremental transfers
- Supports both `dev-to-prod` (default) and `prod-to-dev` directions
- Excludes `.gitkeep`, temp files, `.DS_Store`, `Thumbs.db`
- Fixes file permissions (`www-data` ownership, 755/644) after sync
- Shows file count and transfer summary

---

Files (use skills_tool method=read_file to open):
/a0/skills/wordpress-bedrock-setup/
├── scripts/
│   ├── sync-db-full.sh
│   ├── sync-content-selective.sh
│   └── sync-uploads.sh
└── SKILL.md
