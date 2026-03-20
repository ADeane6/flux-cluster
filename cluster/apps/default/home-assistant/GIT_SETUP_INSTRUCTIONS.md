# Home Assistant Config Git Setup

This file contains instructions for initializing git in your Home Assistant config directory.

## Initial Setup (Run in code-server terminal)

```bash
# Navigate to config directory
cd /config

# Copy .gitignore from this directory
# (You'll need to manually create it first - see .gitignore content below)

# Configure git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Initialize git repository
git init

# Add GitHub as remote (replace with your repo)
git remote add origin git@github.com:yourusername/ha-config.git

# Configure SSH to not do host key checking (for automated sync)
mkdir -p ~/.ssh
cat >> ~/.ssh/config << 'EOF'
Host github.com
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

# Add all files (respecting .gitignore)
git add .

# Initial commit
git commit -m "Initial Home Assistant configuration"

# Push to GitHub
git push -u origin main
```

## Daily Usage

After making changes in Home Assistant:

```bash
cd /config
git add .
git commit -m "Update configuration"
git push
```

## Working Locally with Claude Code

```bash
# Clone the repo locally
git clone git@github.com:yourusername/ha-config.git ~/ha-config

# Work with Claude Code
cd ~/ha-config
claude

# After making changes locally
git add .
git commit -m "Your commit message"
git push

# Then pull changes in code-server terminal
cd /config
git pull
```

## Files Tracked

The `.gitignore` excludes:
- Database files (*.db, *.db-shm, *.db-wal)
- Log files
- Backups
- Cache directories (deps/, tts/, image/, www/)
- secrets.yaml (keep your secrets secure!)

## Files You Should Track

- configuration.yaml
- automations.yaml
- scripts.yaml
- scenes.yaml
- All YAML configs
- Custom components
- Templates and themes
- Blueprints (if custom)

## Secrets Management

**Important:** `secrets.yaml` is excluded from git. Options:
1. Store secrets in a password manager
2. Use a separate encrypted secrets repo
3. Document required secrets in a `secrets.yaml.example` file
