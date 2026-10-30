# BetterBar

Gestionnaire de la barre des menus pour macOS 27. Les icônes sont réparties entre **Toujours masqué**, **Masqué** et **Visible**.

## Utilisation

- **⌘-glisser une icône** affiche les séparateurs et affecte son app à la section où tu la déposes. Toutes les icônes d’une même app sont masquées ou affichées ensemble. BetterBar ne déplace jamais les icônes : leur ordre reste le tien, et un déplacement sans ⌘ ne change pas la section.
- **Cliquer dans un espace vide** affiche ou masque la section Masqué. **⌥-cliquer** affiche ou masque toutes les sections.
- Le deuxième clic d’un double clic (et les suivants) est ignoré : le premier clic agit normalement. En dehors d’un ⌘-glisser, seul **⌥-clic** révèle la section Toujours masqué.
- **Cliquer droit dans un espace vide** ouvre le menu Réglages et Quitter.
- Le masquage automatique et son délai se règlent dans la fenêtre de réglages. Un menu ouvert suspend le masquage. Un clic hors de la barre des menus masque aussitôt, sauf dans un menu ou une fenêtre ouverts depuis une icône.
- Les séparateurs peuvent être un chevron, un point ou un espace. Ils apparaissent pendant le ⌘-glisser et restent affichés, avec toutes les sections, tant que ⌘ est enfoncé : on peut déposer plusieurs icônes à la suite.
- **Appliquer** un espacement propose de relancer les apps concernées ou d’attendre leur prochain lancement. Les apps qui refusent de quitter restent ouvertes. Les éléments Apple sont exclus des relances.
- BetterBar apparaît dans le Dock et dans ⌘Tab tant que la fenêtre de réglages est ouverte.

Ne lance pas BetterBar en même temps qu’Ice, Thaw ou Bartender : leurs mécanismes de masquage peuvent se remplacer.

## Construire

Prérequis : un Mac Apple Silicon, macOS 27 et Xcode avec le SDK macOS 27. Les outils Apple `swiftc`, `sips`, `iconutil` et `codesign` doivent être disponibles. Aucune dépendance tierce n’est nécessaire.

```sh
make build     # produit build/BetterBar.app sans l’installer
make test      # tests automatisés sans relancer les apps de l’utilisateur
make check     # compilation, tests et vérification des scripts/plist/signature
make run       # construit, installe dans /Applications et lance
make clean     # supprime les fichiers générés dans build/
```

`make cert` crée un certificat auto-signé « BetterBar Signing » dans le trousseau pour conserver la même identité entre les builds. Sans certificat, la compilation utilise une signature ad hoc. `make install` remplace la copie de `/Applications/BetterBar.app` ; `make uninstall` la retire et efface les préférences BetterBar.

Au premier lancement, autorise BetterBar dans **Réglages Système → Confidentialité et sécurité → Contrôle de l’appareil et accès aux données** (anciennement « Accessibilité »), puis relance-la. Cette autorisation permet de détecter les clics et les déplacements d’icônes. Le masquage fonctionne sans elle.

## Tests en session graphique

```sh
make test-spacing-relaunch
```

Ce test nécessite macOS 27 et l’accès Accessibilité. Quitte d’abord BetterBar et les autres gestionnaires qui masquent les icônes. Il utilise une app jetable, mesure l’espacement réel avant et après sa relance et vérifie le refus de quitter. Il modifie temporairement les préférences globales d’espacement et les restaure à la fin ; aucune autre app n’est relancée.

## Organisation du dépôt

- `Sources/Core/` : sections, états, identité, disposition et classification des clics.
- `Sources/App/` : intégration AppKit, Accessibilité, masquage, réglages et relance des apps.
- `Tests/` : tests de logique et app utilisée par le test d’intégration.
- `scripts/` : génération d’icône, certificat de signature et test d’intégration.
- `Resources/` : PNG source de l’icône et attribution/licence associées.
- `docs/macos-27.md` : observations techniques et limites des API de macOS 27.
- `build/` : bundle, icône compilée, exécutables et résultats générés, ignorés par Git.

L’icône violette est adaptée de celle d’Ice : voir [l’attribution](Resources/NOTICE.md) et [la licence GPL-3.0](LICENSE). Le code de BetterBar n’est pas repris d’Ice ou de Thaw.

## Licence

BetterBar est distribué sous licence GNU GPL-3.0. Voir [LICENSE](LICENSE).
