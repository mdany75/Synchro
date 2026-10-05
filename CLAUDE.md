# CLAUDE.md — Synchro

Application macOS (SwiftUI) qui fait un miroir d'un dossier ou d'un disque (le SSD de photos de Dany) vers un NAS en SMB : copie ce qui est nouveau, efface de la destination ce qui n'est plus dans la source, après un aperçu à confirmer. Pour un photographe, pas un programmeur.

Ce projet suit le standard commun des projets de Dany (`/standard-projet` le vérifie).

## Commandes

| Action | Commande |
| --- | --- |
| Construire | `./build.sh` (tests, puis `build/Synchro.app` et `build/Synchro.dmg` ; `--install` installe dans `/Applications`) |
| Tester | `./test.sh` (moteur, puis déroulement d'une tâche ; dossiers temporaires seulement) |
| Analyser sans interface | `build/Synchro.app/Contents/MacOS/Synchro --plan <source> <destination> [--exclude <chemin>]…` (n'écrit rien ; `--run` exécute aussitôt, sans aperçu) |
| Capture hors écran | `CFFIXED_USER_HOME=<faux dossier personnel> SYNCHRO_DEMO=copie build/Synchro.app/Contents/MacOS/Synchro --snapshot capture.png` |

Les fichiers produits vont dans `build/`, ignoré par git. Rien de compilé n'est commité.

## Publier une version

Dans cet ordre :

1. Mettre le numéro à jour (`VERSION=` dans `build.sh`) et ajouter la section `## X.Y — date` dans `CHANGELOG.md`.
2. `git add -A && git commit -m "Version X.Y" && git push origin main`
3. `./build.sh` (produit `build/Synchro.dmg` ; refuse un dépôt non validé)
4. `git tag -a vX.Y -m "Version X.Y" && git push origin vX.Y`
5. `gh release create vX.Y build/Synchro.dmg --title "Synchro X.Y" --notes "$(~/.claude/skills/standard-projet/scripts/notes-version.sh X.Y)"`

Le README pointe vers `releases/latest/download/Synchro.dmg`.

## Règles

- Répondre et écrire (commits, README, textes de l'interface) en français.
- Ne jamais écrire, effacer ni renommer sous `/Volumes` (le SSD `/Volumes/Photos` et le NAS `/Volumes/Backup` sont les vraies données) : les tests et les essais utilisent des dossiers temporaires. Une analyse (`--plan`) sur les vrais volumes est permise : elle ne fait que lire.
- Ne jamais `pkill`/`killall Synchro` : l'app de Dany peut être en train de synchroniser. Ne tuer que les processus qu'on a lancés.
- Pas de Xcode sur ce Mac, seulement les Command Line Tools : `@State` et `@Test` sont des macros dont le module manque. Les vues utilisent `@Local` (Views.swift) à la place de `@State`, et `test.sh` passe `-plugin-path` pour les tests. Ne pas réintroduire `@State`.
- Sur un partage réseau, poser les dates d'un fichier après sa mise en place sous son vrai nom, jamais sur le fichier temporaire (le serveur les réécrit à la fermeture réelle).
- L'`Info.plist` est écrit par `build.sh` ; le numéro de version y est `VERSION=`.
- Toute modification du moteur (`Sources/SynchroCore`) passe par `./test.sh` ; une correction de perte de données possible a son test de régression.
- Avant de pousser une fonctionnalité : README et CHANGELOG à jour, capture d'écran (`docs/capture.png`) refaite si l'interface a changé, et une nouvelle version si ce qu'on installe a changé.
- Pousser sur `main` directement.

## Organisation

- `Sources/SynchroCore/` : moteur (analyse, plan, copie, garde-fous), sans interface
- `Sources/Synchro/` : app SwiftUI, journal, notifications, mode ligne de commande
- `Tests/` : tests du moteur et du déroulement d'une tâche
- `Resources/` : icône ; `scripts/make-icon.swift` la dessine
- `docs/` : captures d'écran du README
