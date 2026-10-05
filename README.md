<p align="center"><img src="docs/icone.png" width="128" alt="Icône de Synchro"></p>

# Synchro

Application macOS native (SwiftUI) qui fait un **miroir** d'un dossier ou d'un disque vers un autre emplacement — typiquement un SSD de photos vers un NAS en SMB. La destination devient une copie exacte de la source : les nouveautés sont copiées, et ce qui n'existe plus dans la source est effacé de la destination.

![Fenêtre de Synchro pendant une synchronisation](docs/capture.png)

*Capture réalisée avec des données fictives.*

## Fonctions

- **Tâches** : chaque tâche garde sa source, sa destination et ses éléments ignorés. Ajoutez-en autant que voulu.
- **Aperçu avant d'agir** : Synchro analyse d'abord, puis liste ce qui sera copié et ce qui sera effacé. Rien n'est modifié sans confirmation.
- **Suivi en direct** : durée, temps restant, vitesse de transfert, volume transféré, nombre de fichiers copiés, effacés et inchangés.
- **Éléments ignorés** : dans l'arborescence de la source, cliquez la flèche → d'un dossier ou d'un fichier pour la changer en ✕. Un élément ignoré n'est ni copié ni effacé de la destination.
- **Fichiers cachés** ignorés (désactivable par tâche). Les fichiers système de macOS (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `._*`…) sont toujours ignorés.
- **Destination SMB** : saisissez `smb://serveur/partage/dossier`. Le partage est monté au besoin ; le mot de passe vient du Trousseau macOS et n'est jamais stocké par l'app.
- **Glisser-déposer** d'un dossier ou d'un alias sur les champs Source et Destination.
- **Modifications confirmées** : les changements d'une tâche ne sont gardés qu'après « Enregistrer », et l'app avertit si vous quittez sans l'avoir fait.
- **Notification et son** à la fin de chaque synchronisation.

## Comment ça marche

- Un fichier est recopié si sa taille ou sa date de modification diffère (tolérance de 2 s pour les horodatages SMB).
- Chaque fichier est écrit sous un nom temporaire puis renommé : une copie interrompue ne laisse jamais de fichier tronqué sous son vrai nom.
- Les noms accentués sont comparés sous forme Unicode normalisée, pour qu'un « é » du Mac et un « é » du NAS soient reconnus comme identiques.
- Si la source est vide ou introuvable, toute suppression est bloquée.
- Les liens symboliques ne sont pas copiés.
- Le Mac ne se met pas en veille pendant une synchronisation.

## Installation

Il faut macOS 14 ou plus récent (Apple Silicon ou Intel).

1. Téléchargez **[Synchro.dmg](https://github.com/mdany75/Synchro/releases/latest/download/Synchro.dmg)**.
2. Ouvrez-le et glissez **Synchro** sur le dossier **Applications**.
3. Lancez Synchro, puis suivez la section « Autorisations » ci-dessous : le premier lancement est bloqué par macOS.

## Autorisations

### Premier lancement : « Ouvrir quand même »

Synchro n'est pas signée avec un certificat Apple payant. Au premier lancement, macOS affiche donc un message du type « Apple n'a pas pu vérifier que Synchro ne contient pas de logiciel malveillant ». Pour l'autoriser :

1. Cliquez **Terminé** dans le message (pas « Placer dans la corbeille »).
2. Ouvrez **Réglages Système → Confidentialité et sécurité**.
3. Descendez jusqu'à la section **Sécurité** : une ligne indique que Synchro a été bloquée. Cliquez **Ouvrir quand même**.
4. Confirmez avec votre mot de passe ou Touch ID, puis **Ouvrir**.

C'est à faire une seule fois. Autre méthode, dans le Terminal :

```bash
xattr -dr com.apple.quarantine /Applications/Synchro.app
```

### Accès aux disques et au réseau

À la première utilisation, macOS demande d'autoriser Synchro à accéder aux **volumes amovibles** (le SSD) et aux **volumes réseau** (le NAS). Cliquez **Autoriser**.

Si vous avez refusé par erreur, la source reste vide ou l'analyse échoue. Pour corriger : **Réglages Système → Confidentialité et sécurité → Fichiers et dossiers → Synchro**, puis activez « Volumes amovibles » et « Volumes réseau ».

### Notifications

Au premier lancement d'une synchronisation, macOS demande d'autoriser les notifications. Pour changer d'avis plus tard : **Réglages Système → Notifications → Synchro**. Sans cette autorisation, seul le son de fin est joué.

### Mot de passe du NAS

Synchro ne demande ni ne stocke le mot de passe. Connectez le partage une fois dans le Finder (**Aller → Se connecter au serveur…**, ⌘K) en cochant **Conserver ce mot de passe dans mon trousseau** ; Synchro pourra ensuite monter le partage toute seule.

## Compiler soi-même

Il faut les Command Line Tools d'Apple (`xcode-select --install`). Xcode n'est pas nécessaire.

```bash
git clone https://github.com/mdany75/Synchro.git
cd Synchro
./build.sh
cp -R build/Synchro.app ~/Applications/
```

`./build.sh dmg` produit en plus `build/Synchro.dmg`.

## Avertissement

Synchro **efface définitivement** de la destination ce qui n'est plus dans la source. Lisez l'aperçu avant de confirmer, et gardez une autre sauvegarde de ce qui compte.
