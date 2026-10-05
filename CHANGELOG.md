# Changements

## 1.2 — 2026-10-05
### Ajouté
- Flèche jaune, avec le nombre d'éléments ignorés, sur un dossier synchronisé dont une partie du contenu est ignorée.
- `./build.sh` produit l'image disque à chaque fois et accepte `--install`.
### Modifié
- La fenêtre « À propos » n'affiche que « Version 1.2 », sans numéro de compilation.
- Projet mis au standard commun : CHANGELOG, CLAUDE.md, .editorconfig, .gitignore, sections du README.
### Corrigé
- Sur un partage réseau, la date de modification posée sur un fichier copié était réécrite par le serveur : les fichiers copiés gardaient la date du jour et étaient proposés de nouveau à chaque synchronisation. Les dates sont posées une fois le fichier en place, relues aussitôt, puis contrôlées à la fin de la synchronisation.

## 1.1 — 2026-10-05
### Ajouté
- Garde-fous : dossiers imbriqués refusés, source vide bloquée, suppression inhabituelle ou changement de volume à confirmer, arrêt si le disque est débranché ou la destination pleine, aperçu périmé après 30 minutes.
- Comparaison du contenu des fichiers ambigus (rafales renumérotées, fichiers touchés depuis la dernière synchronisation), et comparaison complète à la demande.
- Journal de chaque synchronisation ; notification quand une analyse attend une confirmation.
- Aperçu : tâche, source et destination réelles, nombre de fichiers par dossier à effacer, espace libre, catalogue Lightroom ouvert.
- Dates de création et étiquettes du Finder conservées ; un changement de majuscules seul est un simple renommage.
- Tests automatisés du moteur et du déroulement d'une tâche.
### Modifié
- Lignes Source et Destination non éditables (dossier glissé ou choisi, crayon pour saisir une adresse) ; liste des éléments ignorés ; résultat affiché dans la fenêtre quand il n'y a rien à faire.
### Corrigé
- Une destination qui contenait la source faisait effacer la source elle-même.
- Un dossier ignoré présent seulement sur la destination était effacé avec son dossier parent.
- Des photos de même taille et de même seconde, renumérotées après un tri, passaient pour inchangées.
- Quitter pendant une synchronisation bloquait l'app.

## 1.0 — 2026-10-04
Première version publiée.
