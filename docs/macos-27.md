# Fonctionnement sur macOS 27

Ces constats ont été vérifiés sur macOS 27.0.1 (26A434), par captures d'écran et avec les journaux de MenuBarAgent.

### Ce qui a changé

- Les icônes ne sont plus des fenêtres. MenuBarAgent compose toute la barre dans une seule fenêtre, et `CGWindowListCopyWindowInfo` ne les voit plus. Accessibilité les expose encore : chaque app publie les siennes sous `AXExtrasMenuBar`.
- L'astuce d'Ice ne marche plus. Un `NSStatusItem` séparateur de 10 000 pt est simplement retiré de la barre ; il ne pousse plus rien hors de l'écran.
- Quand la barre est pleine, macOS ajoute son propre chevron « de débordement ».

### Le seul mécanisme de masquage : la restriction de MenuBarAgent

C'est une API privée, `MenuBarClientCore.framework`. `MBAssessmentModeAssertion` et `MBAssessmentModeConfiguration(allowedSystemItems:allowedBundleIdentifiers:)` sont la restriction du « mode évaluation » (examens).

- Elle fonctionne en **liste d'autorisation**. Les bundle IDs listés restent visibles ; les icônes de toutes les autres apps sont masquées.
- La granularité est **l'application**. Les 5 icônes de Stats suivent la même section, et aucune API ne permet de les séparer.
- Les éléments système sont des entiers (`2` = Horloge, `8` = Control Center…). BetterBar les autorise tous : les éléments Apple se gèrent dans Réglages Système → Barre des menus.
- La **dernière assertion active gagne**. Pour changer d'état, on active la nouvelle puis on invalide l'ancienne, sans clignotement.
- Si le processus meurt, même tué brutalement, MenuBarAgent lève la restriction et toutes les icônes reviennent. On ne peut pas « perdre » une icône.
- Si MenuBarAgent redémarre, la restriction tombe. BetterBar la repose quand il détecte son redémarrage et au réveil.

### Identification des apps : le piège

MenuBarAgent ne rattache une icône à son bundle ID que si l'app tourne depuis **`/Applications`** (sous-dossiers compris) ou depuis le système. Ailleurs (dossier de build, `~/Applications`, chemin App Translocation d'une app téléchargée non déplacée), le propriétaire de l'icône vaut `nil`. Aucune liste d'autorisation ne peut alors la nommer : **elle est masquée dès qu'une restriction est active**.

Le test a été fait avec la même app copiée à deux endroits : la copie de `/Applications` était autorisée, celle de `/tmp` restait masquée. C'est la signature de code qui ne compte pas : une app non signée ou auto-signée dans `/Applications` fonctionne. C'est ce qui arrivait à mdeck lancé depuis un worktree.

BetterBar signale ces apps dans les réglages (« Hors de /Applications ») et propose de les afficher dans le Finder.

### Positions et sections

La section est une propriété de l'app, enregistrée dans les préférences. **C'est la seule source de vérité** : on ne la déduit jamais de l'endroit où se trouvent les icônes. C'est la barre qui est rangée pour lui correspondre, de gauche à droite : `Toujours masqué ‹ séparateur ‹ Masqué ‹ séparateur ‹ Visible`.

- Les deux séparateurs sont de vrais `NSStatusItem`. macOS mémorise leur place sous le bundle ID de BetterBar, comme pour toute autre icône. Hors ⌘-glisser, leur longueur est 0 : ils sont invisibles et ne laissent aucun trou, mais Accessibilité donne toujours leur position. Ils délimitent donc les zones en permanence.
- **Au dépôt**, la zone où l'icône a été calée par macOS devient la section de son app. Seule l'app déposée change de section ; les autres gardent la leur.
- **Le rangement** (`Arranger`) lit toute la barre par Accessibilité. Chaque icône hors de la zone de son app est ⌘-glissée par un événement synthétique, comme le ferait l'utilisateur, juste à côté du séparateur qui borne sa zone. L'ordre relatif des icônes est conservé. Le pointeur est remis en place après chaque glisser.
- Observé sur macOS 27 : pendant un glisser, l'icône dépasse un voisin dès que le pointeur franchit le centre de ce voisin, mesuré à sa place d'avant le glisser. Relâcher à mi-chemin entre deux centres insère donc l'icône entre ces deux éléments. Les glisser passent mieux avec des séparateurs de longueur 0 qu'avec des séparateurs affichés.
- **Le rangement déplace le pointeur** : il a lieu au lancement de BetterBar (avant le premier masquage) et après chaque dépôt. Un simple clic de révélation ne déclenche pas de glisser synthétique et ne retarde pas le masquage automatique.
- Seules les icônes affichées sont lues : une icône masquée garde une position périmée dans Accessibilité. Le lancement et les dépôts révèlent temporairement toutes les sections pour les ranger.
- **Toute nouvelle icône apparaît tout à gauche** (vérifié). Une app jamais rangée reste **Visible**, indépendamment de sa position physique ; elle est repositionnée au prochain rangement.
- Les éléments d'Apple (Horloge, Control Center, indicateurs) ne sont jamais déplacés. Ils comptent seulement comme voisins. Une icône qui refuse de bouger est abandonnée après un essai.
- Les icônes réordonnées pendant que BetterBar est quitté sont remises dans leur zone au lancement suivant.
- Masquer puis révéler ne change pas l'ordre : c'est vérifié sur plusieurs cycles, et en ajoutant une icône pendant un masquage.
- La table des positions de macOS (`TrailingItemPreferredPositions`, conteneur `com.apple.MenuBar`) est protégée ; Thaw y écrit, et c'est là qu'il accumule la plupart de ses bugs. BetterBar n'y touche pas : il ne passe que par des ⌘-glisser.

### Apps à plusieurs icônes (Stats, mdeck…)

La restriction de macOS 27 ne connaît que des bundle IDs : **deux icônes d'une même app ne peuvent pas être dans deux sections différentes**. La signature n'y change rien, et Thaw bute sur la même limite avec Stats. La section de l'app est celle de l'icône que tu viens de déposer ; BetterBar déplace aussitôt ses autres icônes dans la même zone.

Il n'existe pas de contournement par icône :

| Piste | Résultat |
| --- | --- |
| Clés `NSStatusItem Visible <nom>` dans les préférences de l'app | AppKit ne les relit pas à chaud |
| Séparateur large (méthode Ice) | macOS 27 retire l'élément de la barre |
| Table des positions | protégée ; Thaw, qui y écrit, ne sépare pas non plus Stats |

**La seule solution fiable, pour une app que tu développes** (mdeck), est de mettre chaque groupe d'icônes dans une petite app helper qui a son propre bundle ID, embarquée dans le bundle. Par exemple `mdeck.app/Contents/Library/Helpers/mdeck App Monitor.app`, avec `LSUIElement` et un bundle ID `com.yohan.mdeck.appmonitor`. C'est vérifié : un helper embarqué dans une app de `/Applications` est identifié par macOS et se masque indépendamment de l'app principale. Pour une app tierce comme Stats, il reste ses propres réglages (désactiver un module).

### Clic dans un espace vide

Le hit-test passe par Accessibilité (`AXUIElementCopyElementAtPosition`) :

| Résultat | Cible |
| --- | --- |
| `AXMenuBar` | espace vide |
| `AXMenuBarItem` + `AXMenuExtra` | une icône |
| `AXMenuBarItem` seul | un menu d'app |

Sur un écran secondaire, macOS 27 dessine les mêmes icônes mais ne rapporte leurs positions que pour un seul écran. BetterBar sonde donc aussi les positions miroir, alignées à droite pour les icônes et à gauche pour les menus. Si l'une de ces sondes tombe sur quelque chose, le clic est ignoré.
