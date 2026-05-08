#!/bin/bash
# =============================================================
# vpn_userdata.sh – Installation automatique Pritunl VPN
# Partagé entre TP1 et TP2
# =============================================================
set -euo pipefail
exec > /var/log/vpn-setup.log 2>&1

echo "=== [$(date)] Installation Pritunl VPN démarrée ==="

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# ── MongoDB 6.0 ─────────────────────────────────────────────
tee /etc/yum.repos.d/mongodb-org.repo <<'EOF'
[mongodb-org]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/6.0/x86_64/
gpgcheck=0
enabled=1
EOF

dnf install -y mongodb-org
systemctl start mongod
systemctl enable mongod
sleep 8

# ── Pritunl ─────────────────────────────────────────────────
tee /etc/yum.repos.d/pritunl.repo <<'EOF'
[pritunl]
name=Pritunl Repository
baseurl=https://repo.pritunl.com/stable/yum/amazonlinux/2023/
gpgcheck=0
enabled=1
EOF

dnf install -y pritunl
systemctl start pritunl
systemctl enable pritunl
sleep 10

# ── Routage IP (requis pour VPN) ────────────────────────────
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

# ── Récupération de la setup-key ────────────────────────────
SETUP_KEY=$(pritunl setup-key 2>/dev/null || echo "ERREUR – relancer: pritunl setup-key")
DEFAULT_PASSWORD=$(pritunl default-password 2>/dev/null || echo "ERREUR – relancer: pritunl default-password")

cat > /home/ec2-user/pritunl-info.txt <<INFO
============================================================
PRITUNL VPN – INFORMATIONS DE CONFIGURATION
============================================================
IP Publique      : $PUBLIC_IP
Interface Admin  : https://$PUBLIC_IP
Setup Key        : $SETUP_KEY
Login initial    :
  Utilisateur    : pritunl
  Mot de passe   : $DEFAULT_PASSWORD

ÉTAPES :
1. Ouvrir https://$PUBLIC_IP (ignorer l'alerte certificat)
2. Entrer la Setup Key
3. MongoDB URI : mongodb://localhost:27017/pritunl
4. Changer le mot de passe admin
5. Créer une Organisation > ajouter des Utilisateurs
6. Créer un Serveur VPN (port 1194/UDP)
   → Attacher l'organisation au serveur
   → Démarrer le serveur
7. Télécharger le profil .ovpn pour chaque utilisateur
8. Importer le .ovpn dans OpenVPN Connect (ou Tunnelblick)

RÉSEAU VPN ATTRIBUÉ : 172.16.0.0/24
RÉSEAU VPC ACCESSIBLE : 10.0.0.0/16
============================================================
INFO

chmod 600 /home/ec2-user/pritunl-info.txt
chown ec2-user:ec2-user /home/ec2-user/pritunl-info.txt

echo "=== [$(date)] Installation Pritunl terminée. IP: $PUBLIC_IP ==="
