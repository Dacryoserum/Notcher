# Notcher

Une app macOS native en **SwiftUI + AppKit** qui transforme le notch en espace de travail. Interface française et anglaise, fond noir et couleur secondaire personnalisable, stockage local, sans dépendance externe.

> **English** — Notcher is a native macOS app (SwiftUI + AppKit) that turns the notch into a workspace: media controls, a file shelf, text sheets, agent quotas, tools, and an overview you compose from widgets. The interface is available in English and French and follows the system language; it can also be chosen in Settings → Behavior. Requires macOS 14 or later. Download the Apple silicon app from the [releases](https://github.com/Dacryoserum/Notcher/releases/latest), unzip it and move it to Applications, or build it on Apple silicon or Intel with `./Scripts/build.sh`. The download is ad hoc signed and not notarized: if macOS blocks the first launch, allow it in System Settings → Privacy & Security → Open Anyway. The rest of this document is in French.

Notcher est une implémentation indépendante inspirée de NotchNook, pas une copie de son code, de ses ressources ou de sa marque.

## Lancer l’app

**macOS 14 minimum**, Mac Apple silicon ou Intel. La compilation produit un binaire pour l’architecture du Mac utilisé.

La [release v1.0.0](https://github.com/Dacryoserum/Notcher/releases/tag/v1.0.0) fournit une archive pour **Apple silicon (arm64)**. Décompresse-la et déplace `Notcher.app` dans Applications. Sur Intel, compile depuis les sources.

L’application construite se trouve dans `dist/Notcher.app`. Double-clique dessus dans le Finder. Elle apparaît dans la barre des menus, sans icône permanente dans le Dock.

Pour reconstruire avec les Command Line Tools de Xcode :

```sh
./Scripts/build.sh
open dist/Notcher.app
```
