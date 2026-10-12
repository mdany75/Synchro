# Changements

## 1.10 — 2026-10-12
### Ajouté
- Pendant la copie, un clic sur la tuile « Vitesse moyenne » affiche la vitesse instantanée (cinq dernières secondes), et inversement ; le choix est mémorisé. Le temps restant reste calculé sur la moyenne.

## 1.9 — 2026-10-12
### Ajouté
- Bouton **Afficher** dans la liste de la source : choisir ce qu'elle montre (identiques, différents, absents, ignorés), réglage mémorisé.
### Retiré
- La fenêtre « Différences » de la 1.7, remplacée par les pastilles et le filtre.

## 1.8 — 2026-10-12
### Ajouté
- Pastille d'état devant chaque ligne de la liste de la source : verte si l'élément est identique sur la destination (même taille, même date), orange s'il est différent, rouge s'il en est absent. Un dossier est vert s'il existe, rouge s'il manque, orange quand la dernière analyse y a trouvé des différences ; après une synchronisation réussie, tout repasse au vert. Calculée dossier par dossier, en une lecture de la destination, et seulement si celle-ci est déjà accessible.

## 1.7 — 2026-10-12
### Ajouté
- **Différences** : « Afficher les différences… » (flèche du bouton Synchroniser) et « Afficher les différences de la sélection » (clic droit dans la liste de la source) ouvrent la même analyse que l'aperçu, en lecture seule : nouveaux ou modifiés avec la raison, seulement sur la destination, inchangés, et « Enregistrer la liste… » en fichier texte. Limitée à une sélection, l'analyse ne lit que ces éléments.
- **Ignorer par lot** dans la liste de la source : sélection par clic, ⌘-clic et ⇧-clic ; clic droit pour ignorer ou synchroniser la sélection, tout le contenu d'un dossier ou tout sauf la sélection ; bouton « Par lot » avec « Tout ignorer » et « Ne plus rien ignorer ».
### Modifié
- Pendant la consultation des différences, la liste des tâches indique « Différences affichées ».

## 1.6 — 2026-10-11
### Ajouté
- Sélecteur **Copie / Image** par tâche, sous la ligne Destination : en mode Copie (le comportement habituel), un élément ignoré déjà présent sur la destination y reste ; en mode Image, il en est effacé, dossier compris. L'aperçu le rappelle. En ligne de commande : `--image`.
### Modifié
- La liste de la source affiche tous les éléments d'un dossier d'un coup, sans bouton « Afficher les 300 suivants ».
- L'étape de copie n'affiche plus « fichier N sur M » ; le nom du fichier en cours reste visible.
- Titre « Synchro » de la barre d'outils réaligné au pixel sur le contenu.

## 1.5 — 2026-10-11
### Ajouté
- Mise à jour proposée : au lancement, au plus une fois par jour, Synchro vérifie sur GitHub si une version plus récente est publiée et propose de l'installer en un clic (téléchargement, contrôle de la signature Developer ID, remplacement de l'app dans son dossier, relance). Menu Synchro → « Rechercher une mise à jour… » pour vérifier tout de suite.
- Pendant la copie, l'étape indique « fichier N sur M », au-dessus du nom du fichier en cours.
### Modifié
- Vitesse et temps restant sont des moyennes depuis le début de la copie, au lieu des dernières secondes : les chiffres ne sautent plus à chaque fichier.
- Le titre « Synchro » de la barre d'outils est aligné sur le contenu de la fenêtre.
- README : plus de manipulation « Ouvrir quand même », l'app étant signée et notarisée depuis la 1.4.

## 1.4 — 2026-10-08
### Modifié
- Application signée avec un certificat Apple Developer ID et image disque notarisée par Apple : plus de « Ouvrir quand même » au premier lancement, et les autorisations d'accès aux disques sont conservées d'une version à l'autre.

## 1.3 — 2026-10-05
### Ajouté
- Menu Fichier → « Exporter les tâches… » et « Importer des tâches… » : les tâches (source, destination, éléments ignorés) s'échangent dans un fichier JSON, par exemple pour les reprendre sur un autre Mac. Une tâche déjà présente à l'identique n'est pas ajoutée deux fois.

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
