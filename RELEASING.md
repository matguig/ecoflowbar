# Publier une release EcoFlowBar

Distribution : **DMG notarisé via GitHub Releases** — pas de site à gérer.

## Une seule fois : le compte Apple

1. S'inscrire à l'[Apple Developer Program](https://developer.apple.com/programs/) (99 $/an).
2. Créer un certificat **Developer ID Application** :
   Xcode → Settings → Accounts → Manage Certificates → « + » → Developer ID Application.
3. L'exporter en `.p12` (clic droit dans Xcode/Trousseau → Exporter) avec un mot de passe.
4. Créer un **mot de passe d'app** sur [appleid.apple.com](https://appleid.apple.com)
   (Connexion et sécurité → Mots de passe d'app).
5. En local, enregistrer le profil de notarisation :

   ```bash
   xcrun notarytool store-credentials ecoflow-notary \
     --apple-id "vous@exemple.fr" --team-id "VOTRETEAMID" --password "xxxx-xxxx-xxxx-xxxx"
   ```

6. Sur GitHub (Settings → Secrets and variables → Actions), créer les secrets
   listés en tête de [.github/workflows/release.yml](.github/workflows/release.yml)
   (`base64 -i cert.p12 | pbcopy` pour `MACOS_CERT_P12`).

## À chaque release

### Via la CI (recommandé)

```bash
git tag v1.0.0 && git push origin v1.0.0
```

GitHub Actions construit l'app autonome, la signe, la notarise et publie le
DMG dans la release. Rien d'autre à faire.

### En local

```bash
EF_SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" \
EF_NOTARY_PROFILE=ecoflow-notary \
./release.sh 1.0.0
```

Sans ces variables, `./release.sh 1.0.0` produit un DMG **ad-hoc de test**
(refusé par Gatekeeper chez autrui — utile seulement en local).

## Ce que contient l'app distribuée

`release.sh` embarque dans `EcoFlowBar.app/Contents/Resources/daemon/` :
les scripts du démon, la bibliothèque BLE, et un **Python autonome**
(python-build-standalone) avec ses dépendances préinstallées.
**Aucun prérequis chez l'utilisateur** : macOS 14+ sur Apple Silicon, c'est tout.
DMG ≈ 50 Mo.
