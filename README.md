# Notcher

Une app macOS native en **SwiftUI + AppKit** qui transforme le notch en espace de travail. Interface française, fond noir et couleur secondaire personnalisable, stockage local, sans dépendance externe.

Notcher est une implémentation indépendante inspirée de NotchNook, pas une copie de son code, de ses ressources ou de sa marque.

## Lancer l’app

**macOS 14 minimum**, Mac Apple silicon ou Intel. La compilation produit un binaire pour l’architecture du Mac utilisé.

L’application construite se trouve dans `dist/Notcher.app`. Double-clique dessus dans le Finder. Elle apparaît dans la barre des menus, sans icône permanente dans le Dock.

Pour reconstruire avec les Command Line Tools de Xcode :

```sh
./Scripts/build.sh
open dist/Notcher.app
```

Pour développer :

```sh
./Scripts/run.sh
```

Tu peux ouvrir `Package.swift` dans Xcode. Utilise le bundle généré par `build.sh` pour les permissions caméra, calendrier, notifications et l’ouverture à la connexion : `swift run` ne crée pas un bundle d’application complet.

Survole le notch, clique dessus ou utilise **⌘ ⇧ Espace**. Épingle le panneau pour le garder ouvert. Échap ou le chevron en haut à droite le referme. Le panneau se déplie vers le bas depuis le bord supérieur. Sur un écran sans notch, une petite capsule occupe le haut de l’écran.

Dans **Réglages → Apparence**, un aperçu vivant du notch reflète chaque choix : couleur (palette ou couleur libre), disposition de l’aperçu, taille, style des onglets, contenu du notch fermé, animation et onglets affichés, tous présentés sous forme de tuiles illustrées. **Comportement** regroupe le survol, le délai de fermeture, le retour haptique, l’écran et l’ouverture à la connexion ; **Services** les médias, le presse-papiers, le dépôt et les agents. Les choix sont enregistrés et appliqués immédiatement. Le fond reste noir.

**Réglages → Widgets** compose l’aperçu : deux rangées de un à trois widgets, à déplacer par glisser-déposer, à élargir ou rétrécir, à ajouter ou retirer, avec le choix de la rangée la plus haute. Dix widgets sont disponibles (Médias, Pomodoro, Volume, Agenda, Texte, Presse-papiers, Dépôt, Batterie, Quotas, Horloge) et chacun adapte sa forme à sa case. Quand un widget reprend le contenu d’un onglet, cet onglet est renommé (« Texte » devient « Fiches », « Dépôt » devient « Fichiers », « Agents » devient « Détails ») et peut être masqué.

**Réglages → Comportement** propose trois façons d’ouvrir le panneau : au survol, au clic, ou « survol puis clic » (le notch vibre et grossit légèrement au survol, un clic l’ouvre). Le volume suit les touches du clavier en temps réel, une lecture en pause depuis plusieurs minutes libère le notch fermé, le titre s’affiche brièvement quand la chanson change, et ⌘1 à ⌘5 changent d’onglet.

Si NotchNook ou un autre utilitaire occupe déjà le notch, quitte cet utilitaire pour éviter la superposition.

## Fonctionnalités livrées

| Espace | Fonctionnement |
| --- | --- |
| Notch | Géométrie issue de `NSScreen`, survol, clic, épinglage, raccourci global, espaces et plein écran, choix de l’écran, ailes latérales au repos sans dépassement sous l’encoche, clic droit pour quitter, animations respectant la réduction des mouvements |
| Médias | Lecture du lecteur actif déclaré à macOS, titre, artiste, album, pochette système avec récupération complémentaire Spotify, progression, précédent/suivant, lecture/pause, déplacement dans la piste |
| Audio | Volume de la sortie système, sourdine, liste des sorties et changement de périphérique, indicateur compact lors des variations de volume |
| Dépôt | Import par glisser-déposer ou sélecteur, fichiers et dossiers, copie indépendante, export par glisser-déposer, recherche, aperçu Quick Look, Finder, AirDrop, copie vers le presse-papiers |
| Conservation | Limite totale de 2 Go, retrait des copies après 1 h / 24 h / 7 j ou conservation manuelle, épinglage exempt de nettoyage, index persistant |
| Texte | Trois fiches accessibles par des repères géométriques, fiches supplémentaires avec +, sélection restaurée, éditeur AppKit monospace avec annulation par fiche, copie et export TXT, JSON formaté/compacté, Base64, encodage URL, nettoyage, tri et dédoublonnage des lignes, annulation de la dernière transformation |
| Agents | Quotas Claude Code et Codex réellement fournis, fenêtres de réinitialisation, distinction des relevés anciens/expirés/absents, alerte à partir de 90 % |
| Focus | Minuteur persistant, pause/reprise, durées prédéfinies et personnalisées, notification et son de fin, tâches persistantes |
| Agenda | Mois navigable, sélection d’un jour, repères d’événements, journée entière et événements en cours, calendrier d’origine, ouverture des liens Google Meet, Zoom, Teams et Webex |
| Miroir | Aperçu caméra local ; arrêt à la fermeture du panneau, au changement de vue et à la sortie de l’app |
| Presse-papiers | Activation facultative, 30 textes en mémoire, filtre des marqueurs confidentiels et de plusieurs gestionnaires de mots de passe, copie et effacement |
| Raccourcis | Liste et lancement des raccourcis de l’app macOS Raccourcis |
| Système | Maintien de l’écran éveillé, luminosité de l’écran intégré compatible, appareils Bluetooth appairés et connectés |
| Prompteur | Défilement de la note sélectionnée, pause, vitesse et inversion horizontale |
| Conversion | Images vers PNG, JPEG, TIFF ou PDF, résultat ajouté au dépôt |
| Réglages | Couleur secondaire, dispositions, taille et navigation, ouverture à la connexion via Service Management, options du notch, rétention, presse-papiers, intégrations Claude/Codex |

### Médias : Spotify, Pistolame, Apple Music, navigateurs

La passerelle interroge la session **Now Playing de macOS**, et ne se limite pas à Spotify. Pistolame est identifié par `com.dacryoserum.pistolame`. Le lecteur doit publier sa session à macOS ; une application qui ne le fait pas ne peut pas être reconnue par cette méthode. Une seule session système active est affichée.

La lecture universelle passe par `MRNowPlayingRequest` / `MRNowPlayingController` dans une passerelle JavaScript for Automation isolée. Il s’agit d’une **interface privée de macOS**, susceptible de changer. La passerelle échoue proprement, n’injecte pas de JavaScript dans les pages et ne demande pas l’accès Accessibilité. Certaines applications ne publient pas la pochette, la durée ou la position, et ne répondent pas à toutes les commandes. Aucun visuel de pochette ou titre fictif n’est présenté comme une lecture réelle.

Depuis la version **0.4.0**, lorsque Spotify est le lecteur actif, l’état de lecture et la position viennent directement de ses propriétés `player state` / `player position`. Les commandes utilisent `play` et `pause` explicites, sont sérialisées et confirmées par une nouvelle lecture. Une réponse lancée avant une commande ne peut plus la remplacer. Le compteur se fige immédiatement pendant une demande de pause et l’extrapolation est bornée si un service cesse de répondre. L’autorisation Automatisation de Spotify est nécessaire à cette synchronisation directe.

Pour Spotify, si macOS ne fournit pas l’image, Notcher lit la propriété `artwork url` documentée dans le dictionnaire de scripts de l’app installée (`Spotify.sdef`), puis télécharge cette image en HTTPS. macOS peut demander l’autorisation d’automatiser Spotify. Le titre, l’artiste et l’album doivent correspondre au lecteur actif. Le chargement est annulable, limité à 6 Mo, réduit à 320 px et mis en cache pour 24 morceaux. Une réponse tardive ne peut pas remplacer la pochette du morceau courant. Les barres du notch indiquent l’état de lecture, sans mesurer le signal audio.

La source publique Apple `MPNowPlayingInfoCenter` sert à **publier la lecture de sa propre app**, pas à lire universellement les autres lecteurs. Voir [la documentation Apple](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) et [la recherche MediaRemote de SKaplanOfficial](https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de).

### Connecter Claude Code

1. Place l’app à son emplacement définitif avant de connecter Claude.
2. Dans **Agents → Connecter Claude Code**, ou les réglages, installe le relais.
3. Relance Claude Code, puis utilise une session normalement.

L’intégration modifie uniquement `statusLine` dans `~/.claude/settings.json`. Elle conserve les autres réglages, sauvegarde la valeur précédente et continue d’exécuter une éventuelle barre d’état existante. Le bouton de retrait restaure cette valeur ; si l’utilisateur a modifié la commande depuis, il refuse de l’écraser.

Le relais reçoit les données de la barre d’état, mais ne conserve que le nom du modèle, le pourcentage de contexte, le coût de session et les fenêtres de quota. Il ne conserve ni prompts, ni conversations, ni chemins de projet, ni jetons d’authentification. Les données sont mises à jour quand Claude Code émet sa barre d’état, pas par un appel réseau de Notcher.

Les champs `rate_limits` dépendent de la version et du compte Claude Code. Ils peuvent être absents, notamment avant la première réponse ou lorsque la formule ne les fournit pas. Une absence n’est jamais transformée en « 0 % ». [Schéma officiel de la barre d’état Claude Code](https://code.claude.com/docs/en/statusline).

### Connecter Codex

Connecte-toi d’abord dans ton CLI Codex habituel. Puis clique **Agents → Connecter Codex**.

Notcher trouve le CLI dans le `PATH`, Homebrew, `~/.local/bin`, les installations NVM ou l’app Codex. Un chemin explicite peut être choisi dans les réglages. Il lance un processus `codex app-server`, effectue le handshake JSON-RPC et lit `account/rateLimits/read` toutes les deux minutes. Il n’ouvre aucune conversation, n’effectue aucune génération et ne lit pas `auth.json`. Le CLI gère lui-même son authentification et ses éventuels fichiers de fonctionnement.

Le bucket `codex` est privilégié, avec compatibilité pour l’ancien schéma mono-bucket. Les réponses sans quotas sont affichées comme indisponibles. Les erreurs de connexion sont visibles et les requêtes expirent après 15 secondes. [Protocole officiel Codex App Server](https://learn.chatgpt.com/docs/app-server).

## Données et permissions

Les fichiers de l’app sont stockés dans `~/Library/Application Support/Notcher/` :

```text
Notcher/
  Shelf/index.json        index des copies
  Shelf/<UUID>/           copies temporaires des fichiers
  notes.json              notes
  focus.json              minuteur et tâches
  Integrations/           relais Claude et relevé filtré
  Conversions/            résultats des conversions
```

- Le dépôt ne déplace et ne supprime jamais les originaux. Seules ses propres copies sont nettoyées.
- Un dossier contenant des liens symboliques est refusé afin de ne pas laisser une copie pointer vers les originaux ; dépose directement la cible du lien à la place.
- Un index ou un fichier de notes illisible est conservé au lieu d’être réécrit silencieusement.
- Les notes et les copies ne sont pas chiffrées par l’app ; elles bénéficient des protections du compte macOS et de FileVault lorsqu’il est activé.
- Le presse-papiers n’est pas écrit sur disque. Le filtrage des marqueurs confidentiels n’est pas une détection universelle de secrets.
- La caméra et le calendrier sont autorisés lors de leur activation. Les notifications sont demandées au démarrage d’un minuteur. La fonction Bluetooth peut dépendre des permissions du système.
- L’app ne contient pas de télémétrie, de compte Notcher ou de serveur distant. Les pochettes Spotify sont téléchargées depuis l’URL fournie par Spotify. Codex communique avec ses services via son propre CLI ; AirDrop, les lecteurs et les raccourcis gardent leur comportement macOS habituel.
- L’app n’active pas App Sandbox, afin de gérer les fichiers déposés et de communiquer avec les CLI. Le « sandbox de texte » est un bloc-notes local avec transformations : il n’exécute pas de code.

## Limites et périmètre

Cette version couvre les fonctions listées ci-dessus. Ce n’est **pas une parité intégrale certifiée avec toutes les versions de NotchNook Pro** : les paroles synchronisées, les approbations interactives Claude/Codex, un terminal PTY, la conversion audio/vidéo et la surveillance universelle des téléchargements ne sont pas implémentés. La liste Bluetooth ne constitue pas un suivi de batterie AirPods.

La luminosité utilise DisplayServices et cible l’écran intégré compatible. Certaines sorties HDMI/USB n’exposent pas de volume système ; le curseur est alors désactivé. Les autorisations calendrier/caméra et la lecture active doivent être vérifiées sur le Mac utilisateur. Les appels de lecture/commande média dépendent d’interfaces non publiques.

Le bundle est signé **ad hoc** pour le développement local, sans certificat Developer ID ni notarisation. Une distribution publique nécessite une signature et une notarisation avec un compte Apple Developer.

## Vérifier et développer

Depuis la version **1.0.0**, l’ouverture et la fermeture ne redimensionnent plus la fenêtre à chaque image : la fenêtre prend d’abord une taille capable de contenir les deux états, SwiftUI anime la forme à l’intérieur avec un ressort (interruptible, vitesse conservée), puis la fenêtre reprend sa taille exacte au repos. Trois styles d’animation sont proposés (Fluide, Vive, Rebond). Le trackpad vibre à l’ouverture, à la fermeture, aux changements d’onglet, à l’épinglage et au dépôt d’un fichier. La réduction des animations est respectée.

L’adresse de la pochette Spotify est lue en même temps que le morceau, puis retentée rapidement (0,6 s, 1,5 s, 3 s…) si Spotify ne l’expose pas encore juste après un changement de piste ; une adresse corrigée remplace la pochette affichée. Les durées non finies sont neutralisées, la lecture est interrogée moins souvent quand le notch est fermé et silencieux, et une seule instance de l’app peut tourner : la relancer ouvre le panneau.

L’espace Texte contient au moins trois fiches indépendantes, plus un bouton d’ajout. Les anciennes notes sont reprises avec leurs identifiants et leur contenu. La dernière fiche sélectionnée est restaurée ; chaque fiche conserve son curseur, son défilement et son annulation pendant l’utilisation de l’éditeur. L’écriture sur disque est sérialisée en arrière-plan, puis terminée à la fermeture de l’app.

Depuis la version **0.3.0**, les événements du calendrier sont lus hors du fil de l’interface. Le panneau fermé conserve exactement la hauteur de la zone supérieure de l’écran ; seules ses ailes changent de largeur selon l’activité. Le menu contextuel propose « Quitter Notcher ». L’agenda utilise un mois et une journée sélectionnée, avec des calculs respectant le fuseau horaire et les changements d’heure. Référence fonctionnelle : [le calendrier de Vorssaint](https://vorssaint.com/).

Depuis la version **0.2.0**, les interrogations Bluetooth, audio et luminosité sont exécutées dans des processus séparés, avec un délai maximal de trois secondes. Les requêtes en doublon sont évitées et la lecture audio temporise ses nouvelles tentatives après une erreur. Fermer la vue Système annule la lecture Bluetooth en cours. Un pilote bloqué n’immobilise donc pas le fil de l’interface.

Les commandes asynchrones sont annulables, y compris lorsqu’un processus refuse SIGTERM ou qu’un descendant conserve sa sortie ouverte. Le repli automatique vérifie l’édition de texte et l’épinglage ; le simple fait de cliquer sur un onglet ne le désactive plus. Les sélecteurs de fichiers n’épinglent plus durablement le panneau.

```sh
./Scripts/test.sh
./Scripts/build.sh release
codesign --verify --deep --strict --verbose=2 dist/Notcher.app
```

Les tests couvrent le stockage, les quotas, le minuteur, les transformations, l’installation/restauration Claude et le protocole Codex. Ils vérifient aussi l’ancrage de l’animation, son interruption, le repli après interaction, les erreurs et reprises Bluetooth, l’indépendance audio/luminosité et les délais/cancellations des sous-processus. Ils couvrent également la hauteur de tous les états compacts, le cache et les annulations de pochettes, les événements nocturnes, les fins de journée exclusives, les années bissextiles et les changements d’heure. Les régressions de pause Spotify, les réponses périmées, les commandes rapprochées, les migrations de fiches, la sauvegarde finale et la géométrie de la fenêtre de transition et les nouvelles tentatives de pochette sont également testées.

Les tests utilisent des répertoires temporaires et ne changent pas les réglages réels de Claude/Codex. `Scripts/test.sh` utilise le Xcode complet lorsqu’il est installé pour trouver XCTest.

```sh
# Aperçu dans une fenêtre normale, sans lancer les services système
dist/Notcher.app/Contents/MacOS/Notcher --preview

# Captures des vues dans une session graphique macOS
NOTCHER_DATA_DIR="$PWD/.test-data" \
  dist/Notcher.app/Contents/MacOS/Notcher --render-previews
```

`NOTCHER_DATA_DIR` isole les données de développement. Les prévisualisations ne contiennent pas de faux quotas ou de faux morceaux. Une session graphique macOS est nécessaire pour tester réellement les contrôles AppKit, le drag-and-drop et les permissions.

Architecture : `Sources/NotcherCore` contient les modèles et opérations testables sans interface ; `Sources/Notcher/Services` les intégrations ; `Sources/Notcher/App` le cycle de vie et les fenêtres ; `Sources/Notcher/Views` les composants SwiftUI. Aucune dépendance Swift Package tierce n’est nécessaire.
