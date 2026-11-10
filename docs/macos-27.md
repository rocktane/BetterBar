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

La section est une propriété de l'app, enregistrée dans les préférences. **C'est la seule source de vérité** : en dehors d'un ⌘-glisser, on ne la déduit jamais de l'endroit où se trouvent les icônes. Le masquage passe par la restriction, qui masque toutes les icônes d'une app absente de la liste où qu'elles soient : **BetterBar ne déplace une icône qu'une fois, quand elle est nouvelle** (voir plus bas). L'ordre de la barre est celui de l'utilisateur.

- Les deux séparateurs sont de vrais `NSStatusItem`. macOS mémorise leur place sous le bundle ID de BetterBar, comme pour toute autre icône. Hors ⌘-glisser, leur longueur est 0 : ils sont invisibles et ne laissent aucun trou, mais Accessibilité donne toujours leur position. De gauche à droite, ils bornent les zones `Toujours masqué ‹ séparateur ‹ Masqué ‹ séparateur ‹ Visible`.
- **Dès le premier ⌘-glisser et tant que ⌘ reste enfoncé**, toutes les sections sont révélées et les séparateurs dessinés, pour que plusieurs icônes puissent être déposées partout à la suite.
- **Masquer juste après avoir révélé** : MenuBarAgent fait apparaître les icônes en fondu ; une restriction qui arrive avant ~0,8 s masque les sections l'une après l'autre (mesuré par captures : à 0,6 s, Masqué disparaît ~130 ms avant Toujours masqué ; dès 0,8 s, tout disparaît ensemble). BetterBar retarde donc un masquage jusqu'à 0,9 s après le dernier affichage.
- **Au dépôt**, `BarReader` lit la barre par Accessibilité une fois qu'elle s'est stabilisée. La zone où macOS a calé l'icône devient la section de son app. Seule l'app déposée change de section ; aucune icône n'est déplacée.
- Seules les icônes affichées sont lues : une icône masquée garde une position périmée dans Accessibilité.
- **Toute nouvelle icône apparaît tout à gauche** (vérifié), donc à gauche des deux séparateurs : dans la zone Toujours masqué. Une app jamais affectée reste **Visible**, indépendamment de sa position physique. Repliée, la barre semble juste ; mais révéler les sections dessine toutes leurs icônes à sa droite, et elle saute tout à gauche.
- **Placement unique des nouvelles icônes** (`IconPlacer`) : la première fois qu'une app sans section a une icône affichée hors de la zone Visible, BetterBar la ⌘-glisse par un événement synthétique dans la zone Visible, puis enregistre l'app (`placedApps`) et ne la déplace plus jamais. Une app déjà dans sa zone, ou affectée par un ⌘-glisser, est enregistrée sans être déplacée. Séparateurs affichés, l'icône va juste après eux. Quand une restriction masque aussi les séparateurs, leur position lue est périmée : l'icône va alors juste après la première icône affichée nettement dans la zone Visible (une app Visible, à droite de toute icône Masqué affichée), et MenuBarAgent l'enregistre à droite du séparateur masqué. Le glisser relâche à mi-chemin entre le centre de ce repère et celui de l'élément suivant : sur macOS 27, une icône glissée dépasse un voisin dès que le pointeur franchit son centre. Une saisie de l'utilisateur (souris, clavier, modificateur) arrête le glisser ; s'il tient le bouton, c'est son relâchement qui le termine. Il n'a lieu ni pendant un ⌘-glisser, ni bouton ou modificateur enfoncé ; le pointeur est remis en place.
- Un déplacement sans ⌘, ou un replacement par macOS, ne change pas la section.
- Les éléments d'Apple (Horloge, Control Center, indicateurs) n'ont pas de section.
- Masquer puis révéler ne change pas l'ordre : c'est vérifié sur plusieurs cycles, et en ajoutant une icône pendant un masquage.
- La table des positions de macOS (`TrailingItemPreferredPositions`, conteneur `com.apple.MenuBar`) est protégée ; Thaw y écrit, et c'est là qu'il accumule la plupart de ses bugs. BetterBar n'y touche pas.
- Cette table donne, pour chaque élément, sa distance au bord droit ; l'ordre de la barre en découle. MenuBarAgent la réécrit après chaque glisser et une dizaine de secondes après la première apparition d'une app (journal `Persisting trailing item positions`). Il relève alors la place de chaque élément **affiché** sur la barre telle qu'elle est dessinée, et garde l'ancienne valeur des éléments masqués.
- **Les séparateurs sont donc masqués avec les sections.** Un séparateur resté affiché pendant que les icônes Masqué sont masquées serait relevé collé à l'autre ; au prochain affichage, ces icônes reviendraient à gauche des deux, dans la zone Toujours masqué, alors que leur app est toujours Masqué. Vérifié avec des apps jetables (deux séparateurs de longueur 0 autour d'une icône masquée, puis lancement d'une nouvelle app) : sans le masquage des séparateurs, les deux séparateurs passent à la même valeur, à droite de l'icône ; avec lui, leurs valeurs ne bougent pas. Masqués, les séparateurs n'occupent aucune place : les icônes voisines ne bougent pas non plus.
- Reste un cas que BetterBar ne peut pas empêcher : quand aucune restriction n'est tenue (aucune app masquée ne tourne, ou tout est révélé), une réécriture peut encore rapprocher les séparateurs autour d'une app quittée. Un ⌘-glisser de son icône la remet dans sa zone.

### Apps à plusieurs icônes (Stats, mdeck…)

La restriction de macOS 27 ne connaît que des bundle IDs : **deux icônes d'une même app ne peuvent pas être dans deux sections différentes**. La signature n'y change rien, et Thaw bute sur la même limite avec Stats. La section de l'app est celle de l'icône que tu viens de déposer ; toutes ses icônes sont masquées ou affichées ensemble, mais BetterBar ne les regroupe pas.

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
