# portable-mac-mini

Indicateur de batterie EcoFlow dans la barre de menus du Mac mini, comme sur un
MacBook — avec autonomie restante, détection « le Mac est-il branché sur
l'EcoFlow ? », et actions automatiques par paliers (notification, mode économie
d'énergie, extinction propre).

Fonctionne **100 % en local via Bluetooth LE** (aucun besoin d'Internet une fois
configuré), grâce au protocole rétro-conçu du projet
[ha-ef-ble](https://github.com/rabits/ha-ef-ble) (Apache 2.0, vendorisé dans
`vendor/eflib`). Testé pour un **River 3 Plus** ; les autres modèles supportés
par eflib fonctionnent aussi.

## Architecture

```
EcoFlow ──BLE──▶ ef_monitor.py (LaunchAgent, démon)
                    │  écrit ~/Library/Application Support/ecoflow-monitor/state.json
                    │  actions : notification / pmset lowpowermode / shutdown
                    ▼
            EcoFlowBar.app ◀── app/EcoFlowBar.swift (SwiftUI MenuBarExtra,
                                panneau style Stats : anneaux, flux, réglages)
```

- **`scripts/ef_login.py`** — étape unique en ligne : récupère l'ID du compte
  EcoFlow (exigé par le protocole BLE V2). Le mot de passe part uniquement vers
  les serveurs EcoFlow et n'est jamais conservé.
- **`scripts/ef_scan.py`** — scan Bluetooth, enregistre le SN de la batterie.
- **`scripts/ef_monitor.py`** — démon : état temps réel + paliers d'action.
- **`app/EcoFlowBar.swift`** — app native barre de menus (compilée par `setup.sh`) :
  anneaux batterie/sortie, autonomie, flux détaillés, réglages des seuils et la
  case « Actions automatiques sur le Mac ».
- **`swiftbar/ecoflow.5s.py`** — affichage alternatif via
  [SwiftBar](https://github.com/swiftbar/SwiftBar) (texte, même contenu) ; pour
  l'utiliser : `ln -s "$PWD/swiftbar/ecoflow.5s.py" ~/.swiftbar/`.

## Installation

```bash
./setup.sh
```

puis suivre les 4 étapes affichées (login, scan, sudoers optionnel, kickstart).

## Affichage

| Icône | Signification |
|---|---|
| `🔋 74% 3:24` | Sur batterie — niveau et autonomie restante (orange ≤ 20 %, rouge ≤ 10 %) |
| `⚡︎ 74%` | En charge |
| `🔌 74%` | Branchée secteur / aucune décharge |
| `⚡︎ –` | EcoFlow hors de portée ou éteinte |
| `⚡︎ ⚠︎` | Démon injoignable |

## Paliers d'action

Tout se règle depuis l'icône → **Réglages** : seuils de chaque palier,
activation individuelle des actions, et la case **« Actions automatiques sur le
Mac »** qui coupe/rétablit l'ensemble du comportement en un clic (l'affichage
continue de fonctionner ; si le mode éco était actif, il est désactivé).
Le démon recharge la configuration à chaud, sans redémarrage.

Fichier sous-jacent : `~/Library/Application Support/ecoflow-monitor/config.json`
(modifiable aussi via `scripts/ef_config.py set|toggle <clé> [valeur]`)

| Seuil | Défaut | Action |
|---|---|---|
| `notify` | 20 % | Notification macOS |
| `lowpower` | 10 % | `pmset -a lowpowermode 1` (nécessite sudoers) |
| `shutdown` | 5 % | Extinction propre — **désactivée par défaut** (`actions.shutdown: true` pour l'activer) |
| `restore` | 15 % | Retour au mode normal (hystérésis) |

Les actions `lowpower`/`shutdown` ne se déclenchent que si le Mac est détecté
comme branché sur l'EcoFlow (sortie AC active et ≥ `mac_watts_min` W) et que la
batterie se décharge. L'extinction est précédée d'un préavis de 60 s
(annulée si l'EcoFlow se met à charger) et passe par une fermeture « aimable »
des applications avant le `shutdown`.

Conseillé en complément : activer le redémarrage automatique au retour du
courant —

```bash
sudo pmset -a autorestart 1 autorestartatconnect 1
```

## Autres fonctions

- **Bascule secteur ↔ batterie** : notification à chaque transition (événement UPS).
- **Alerte température** : cellules ≥ 45 °C, ou charge sous 0 °C.
- **Limite de charge** (Réglages) : écrite dans la batterie (80-85 % recommandé
  au quotidien pour la longévité des cellules LFP ; « Ne pas piloter » par défaut).
- **Interrupteur sortie AC** dans la section Flux (confirmation si le Mac y est
  branché) — commande relayée au démon via `command.json`.
- **Mode éco dès la batterie** (Réglages) : bride le Mac dès le passage sur
  batterie, sans attendre le seuil.
- **Énergie du jour** : Wh entrés/sortis, intégrés depuis l'historique.
- **`update-vendor.sh`** : met à jour `vendor/eflib` depuis ha-ef-ble (en cas de
  firmware EcoFlow qui change le protocole).

## Pseudo-hibernation

Bouton lune du panneau (avec confirmation), ou déclenchée automatiquement par
le palier d'extinction : [scripts/ef_hibernate.sh](scripts/ef_hibernate.sh)
sauvegarde la session — apps ouvertes, onglets Safari (filet de secours),
sessions tmux (via tmux-resurrect s'il est installé) — puis éteint proprement
(chaque app peut enregistrer). Au login suivant, l'agent
`fr.koa.ecoflow-restore` relance les apps et restaure tmux, puis notifie.
La restauration n'est pas parfaite (pas d'hibernation noyau sur les Mac de
bureau) : les apps modernes retrouvent leurs documents via l'enregistrement
automatique ; installer tmux-resurrect est recommandé pour le terminal.
Premier déclenchement : macOS demandera l'autorisation « Automation »
(contrôle de System Events/Safari) — accepter.

## Dépannage

- Journal du démon : `~/Library/Logs/ecoflow-monitor.log`
- Relancer le démon : `launchctl kickstart -k gui/$(id -u)/fr.koa.ecoflow-monitor`
- Premier scan BLE : macOS demande l'autorisation Bluetooth — accepter. Pour les
  scripts lancés à la main, la demande est attribuée au Terminal ; pour le démon,
  au wrapper `EcoFlowMonitor.app` (généré par `setup.sh`, qui déclare l'usage
  Bluetooth). Si le démon reste bloqué : Réglages Système → Confidentialité et
  sécurité → Bluetooth → « + » → ajouter `EcoFlowMonitor.app` (ou, en dernier
  recours, le binaire `/opt/homebrew/.../python3.13`).
- Le protocole BLE est non officiel : une mise à jour firmware EcoFlow peut
  casser la compatibilité. Mettre à jour `vendor/eflib` depuis
  [ha-ef-ble](https://github.com/rabits/ha-ef-ble) dans ce cas.
