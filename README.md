# Devoir – Services Cloud AWS
**Auteur :** [MOUKALLA EWANE SIMON-RAYAN]  
**Cours :** Services Cloud AWS – Ing. BOGNI-DANCHI  
**Région AWS :** eu-central-1 (Frankfurt)

---

## Architecture globale

```
                        ┌─────────────────────────────────────┐
                        │           AWS – eu-central-1         │
                        │                                      │
   Internet ────────────►  ALB TP1 (HTTP:80)                  │
                        │    │         │                       │
                        │  EC2-AZa   EC2-AZb  ← ASG TP1       │
                        │  (Apache)  (Apache)                  │
                        │                                      │
   Internet ────────────►  ALB TP2 (HTTP:80, sticky)          │
                        │    │         │                       │
                        │  EC2-AZa   EC2-AZb  ← ASG TP2       │
                        │  [Nginx]   [Nginx]                   │
                        │  [Odoo ]   [Odoo ]                   │
                        │  [PG   ]◄──►[PG  ] ← réplication    │
                        │                                      │
                        │  RDS MySQL Multi-AZ (TP1)            │
                        │  S3 Bucket + Lambda (TP1)            │
                        │                                      │
                        │  EC2 Pritunl VPN ──────────────────────► Réseau local
                        │  (EIP fixe)                          │   (cloud hybride)
                        └─────────────────────────────────────┘
```

---

## Structure du dépôt

```
devoir-aws/
├── tp1/
│   ├── main.tf              # VPC, EC2/ASG, ALB, RDS, S3, Lambda, VPN
│   ├── variables.tf
│   └── terraform.tfvars     # ⚠️ Non commité (.gitignore)
├── tp2/
│   ├── main.tf              # Odoo 19 HA Master-Master via ASG
│   ├── variables.tf
│   └── terraform.tfvars     # ⚠️ Non commité (.gitignore)
├── scripts/
│   ├── vpn_userdata.sh      # Bootstrap Pritunl VPN (partagé TP1+TP2)
│   └── odoo_userdata.sh     # Bootstrap Odoo + Docker Compose (TP2)
└── README.md
```

---

## TP1 – Architecture EC2 en Haute Disponibilité

### Composants déployés

| Composant | Service AWS | Détail |
|---|---|---|
| Réseau | VPC Multi-AZ | 10.0.0.0/16 – AZ a et b |
| Calcul | EC2 + ASG | min 2, max 4 instances |
| Répartition | ALB | HTTP:80 → EC2:80 |
| Base de données | RDS MySQL 8.0 | Multi-AZ activé |
| Stockage | S3 | Versioning + chiffrement AES256 |
| Serverless | Lambda Python 3.12 | Déclenché par dépôt S3 |
| VPN | Pritunl sur EC2 | EIP fixe |

### Déploiement TP1

```bash
cd tp1/

# 1. Générer la clé SSH
ssh-keygen -t rsa -b 4096 -f tp1-key -N ""

# 2. Configurer terraform.tfvars
cp terraform.tfvars.example terraform.tfvars
# Éditer avec vos mots de passe

# 3. Déployer
terraform init
terraform plan
terraform apply

# 4. Récupérer les outputs
terraform output
```

### Tests TP1 – Haute Disponibilité

```bash
# Test 1 : accès au site web
curl http://$(terraform output -raw tp1_alb_url)

# Test 2 : simulation de panne d'une AZ
#   → Lister les instances ASG
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names tp1-asg \
  --query 'AutoScalingGroups[].Instances[*].[InstanceId,AvailabilityZone]' \
  --output table

#   → Terminer une instance (l'ASG en recrée automatiquement une)
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>

#   → Vérifier que l'ALB continue à répondre
curl http://$(terraform output -raw tp1_alb_url)

# Test 3 : RDS Multi-AZ
aws rds describe-db-instances \
  --db-instance-identifier tp1-mysql \
  --query 'DBInstances[].MultiAZ'
# Attendu : true

# Test 4 : Lambda
aws s3 cp test.txt s3://$(terraform output -raw tp1_s3_bucket)/
aws logs filter-log-events \
  --log-group-name /aws/lambda/tp1-processor \
  --filter-pattern "reçu"
```

---

## TP2 – Déploiement Applicatif Automatisé en HA

### Composants déployés

| Composant | Détail |
|---|---|
| VPN Hybride | Pritunl connecte le réseau local au VPC AWS |
| Conteneurisation | Docker + Docker Compose sur chaque EC2 |
| Application | Odoo 17 (image officielle – remplacer par 19 quand dispo) |
| Base de données | PostgreSQL 15 avec réplication logique |
| HA applicative | Mode Master-Master : 2 nœuds indépendants via ALB |
| Sticky sessions | Activées sur l'ALB (obligatoire pour Odoo) |

### Déploiement TP2

```bash
# ⚠️ Déployer TP1 en premier (TP2 utilise ses ressources)

cd tp2/

# 1. Configurer terraform.tfvars
cp terraform.tfvars.example terraform.tfvars
# Éditer avec vos mots de passe

# 2. Déployer
terraform init
terraform plan
terraform apply

# 3. URL Odoo
terraform output tp2_odoo_url
# Attendre 3-5 minutes que Odoo démarre complètement
```

### Configuration Pritunl VPN (hybridation)

```bash
# Récupérer les infos de connexion
ssh -i tp1/tp1-key ec2-user@$(cd tp1 && terraform output -raw tp1_vpn_ip)
cat /home/ec2-user/pritunl-info.txt
```

Étapes dans l'interface web (`https://<VPN_IP>`) :
1. Entrer la **Setup Key**
2. MongoDB URI : `mongodb://localhost:27017/pritunl`
3. Créer une **Organisation** → ajouter un **Utilisateur**
4. Créer un **Serveur** (port `1194/UDP`)
5. Attacher l'organisation → **Start**
6. Télécharger le profil `.ovpn` → importer dans OpenVPN

### Tests TP2 – Résilience Odoo

```bash
# Test 1 : santé Odoo
curl http://$(terraform output -raw tp2_odoo_url)/web/health
# Attendu : {"status":"pass"}

# Test 2 : simulation de panne d'un nœud maître
#   → Lister les nœuds
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names tp2-odoo-asg \
  --query 'AutoScalingGroups[].Instances[*].[InstanceId,AvailabilityZone,HealthStatus]' \
  --output table

#   → Terminer un nœud maître
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>

#   → Vérifier que l'application reste disponible via l'autre nœud
curl http://$(terraform output -raw tp2_odoo_url)/web/health

# Test 3 : vérifier la réplication PostgreSQL
#   (Connecté via VPN)
ssh -i tp1/tp1-key ec2-user@<IP_NŒUD>
docker exec odoo-db psql -U odoo -c "SELECT * FROM pg_stat_replication;"
docker exec odoo-db psql -U odoo -c "SHOW wal_level;"

# Test 4 : logs du nœud
cat /home/ec2-user/node-info.txt
docker logs odoo-app --tail 50
docker logs odoo-db --tail 20
```

---

## Destruction de l'infrastructure

```bash
# ⚠️ Détruire TP2 en premier, puis TP1
cd tp2 && terraform destroy
cd ../tp1 && terraform destroy
```

---

## Sécurité

| Fichier | Action |
|---|---|
| `tp1/terraform.tfvars` | Dans `.gitignore` – jamais commité |
| `tp2/terraform.tfvars` | Dans `.gitignore` – jamais commité |
| `tp1/tp1-key` | Clé privée SSH – jamais commitée |
| Ports EC2 Odoo | Filtrés : seul l'ALB y accède (8069/8072) |
| SSH | Uniquement depuis le VPC (via VPN Pritunl) |
| RDS | Dans subnets privés, pas exposé à Internet |
