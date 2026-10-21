<p align="center"><img src="docs/icon.png" width="96" alt=""></p>

<h1 align="center">UnbloatMyPhone</h1>

<p align="center">
  Désactivez les applications préinstallées, le pistage et les extras inutiles d'un téléphone Android.<br>
  Pour Windows, macOS et Linux. Des choix en langage clair, une sauvegarde de tout, une annulation en un clic.
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Dernière version" src="https://img.shields.io/github/v/release/matguitarist/UnbloatMyPhone?label=t%C3%A9l%C3%A9charger"></a>
  <img alt="Téléphones Android" src="https://img.shields.io/badge/T%C3%A9l%C3%A9phones%20Android%20%C2%B7%20Google%20Pixel-green">
  <img alt="Windows, macOS, Linux" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux-blue">
  <a href="LICENSE"><img alt="Licence MIT" src="https://img.shields.io/github/license/matguitarist/UnbloatMyPhone"></a>
  <br><sub>Le petit frère pour téléphones d'<a href="https://github.com/matguitarist/UnbloatMyTV">UnbloatMyTV</a>.</sub>
  <br><a href="README.md">English version</a>
</p>

> **Version préliminaire.** La liste des applications est d'abord optimisée pour les Google Pixel.
> Les autres marques ont les composants Android et Google, et l'application vous aide à proposer le reste.

## Téléchargement

Prenez le fichier correspondant à votre ordinateur dans la **[dernière version](../../releases/latest)**.
Rien d'autre à installer : la première fois, l'application télécharge les outils ADB officiels de Google
(environ 7 Mo, depuis `dl.google.com`) dans son propre dossier.

| | Fichier | Premier lancement |
|---|---|---|
| **Windows** 10/11 | `UnbloatMyPhone.exe` | SmartScreen peut indiquer un éditeur inconnu (l'exe n'est pas encore signé) : **Informations complémentaires → Exécuter quand même**. Un Pixel peut avoir besoin du [pilote USB de Google](https://developer.android.com/studio/run/win-usb). |
| **macOS** 14+ | `UnbloatMyPhone-mac.zip` | Application Mac native pour Apple silicon et Intel, signée et notarisée par Apple. Décompressez, placez-la dans Applications et ouvrez-la. |
| **Linux** x64 | `UnbloatMyPhone-x86_64.AppImage` | Rendez-le exécutable (`chmod +x`) et ouvrez-le. En USB, votre utilisateur peut avoir besoin d'accéder au téléphone (paquet `android-udev-rules` sur la plupart des distributions). |

Chaque version se met à jour seule : elle affiche les nouveautés et installe la mise à jour en quelques secondes.

## Ce qu'elle fait

**Nettoyer**
- **Trouve votre téléphone toute seule**, branché en USB ou en Wi-Fi avec le débogage sans fil :
  saisissez le code d'association à 6 chiffres et elle se connecte. Sans root.
- **Ne liste que ce qui est sur votre téléphone**, expliqué simplement : diagnostics, composants
  système inutilisés, fonctions Google, applications préinstallées, réglages de vitesse et de confidentialité.
- **Coche pour vous les choix sans risque.** Ce que vous pourriez utiliser (Photos, Maps,
  l'application Google, Sécurité personnelle…) reste décoché, avec un avertissement sur ce qui cesse de fonctionner.
- **Ne touche jamais à ce dont le téléphone a besoin** : vos applications Téléphone et Messages, le
  clavier, l'écran d'accueil, les Paramètres, les services Google Play, les alertes d'urgence et le cœur d'Android.
- **Bloque publicités et traqueurs pour tout le téléphone** avec un DNS filtrant, testé sur-le-champ et
  annulé s'il casse quelque chose.
- **Sauvegarde, applique, redémarre le téléphone et le vérifie** : écran d'accueil, internet, résolution des noms.

**Garder propre**
- **Remarque quand une mise à jour annule votre nettoyage** et recoche ce qui est revenu en un clic.
- **Les mêmes choix sur le téléphone suivant**, et des choix enregistrables dans un fichier.
- **Annule exactement n'importe quel passage** depuis Restaurer, ou réactive toutes les applications en un clic.
- **Désactive le débogage pour vous** une fois terminé.

**Outils**
- **Bilan de confidentialité** : quelles applications peuvent utiliser votre position (et « en
  permanence »), le micro, l'appareil photo, les contacts, les SMS, le journal d'appels et l'agenda.
  Retirez un accès en un clic ; Restaurer le rend.
- **Infos du téléphone** : version d'Android, âge de la mise à jour de sécurité, la bêta et comment la
  quitter sans rien perdre, bootloader et démarrage validé. Ouvre Mise à jour du système ou l'écran de
  réinitialisation sur le téléphone, et le redémarre normalement, en mode récupération ou en mode
  bootloader (après confirmation).
- **Bilan de santé** : mémoire, stockage, processeur, les applications qui occupent le plus de
  mémoire et celles qui plantent en boucle, avec des conseils clairs. Lecture seule.
- **Mes applications** : les applications que vous avez installées, avec leur icône et leur nom
  comme sur votre téléphone, leur taille, leur version,
  leur date d'installation et leur provenance (Google Play, un fichier, une autre boutique).
  Ouvrez-les, forcez leur arrêt, désactivez-les (annulable depuis Restaurer), archivez-les
  (Android 15 et plus, garde les données) ou désinstallez-les.
  Les applications qui ne viennent pas de Google Play sont listées par nom et signalées, pour que
  vous puissiez les vérifier.
  (Pour les icônes et les noms, un minuscule programme est copié dans le dossier temporaire du
  téléphone, lancé une fois puis supprimé ; rien n'est installé. Son code est dans `helper/`.)
- **Installer une application** : déposez un `.apk` sur la fenêtre.

Rien n'est désinstallé : les applications sont désactivées avec la commande `pm disable-user`
d'Android, et une réinitialisation d'usine remet aussi tout en place. Anglais et français ; les thèmes
clair et sombre suivent votre système.

## Avant de commencer, sur le téléphone

1. **Paramètres → À propos du téléphone** : touchez 7 fois **Numéro de build**, jusqu'à ce qu'il indique que vous êtes développeur.
2. **Paramètres → Système → Options pour les développeurs → Débogage USB** activé.
3. Branchez le téléphone. Pas de câble ? Activez le **Débogage sans fil** dans le même menu, ouvrez
   **Associer l'appareil avec un code d'association** et saisissez le code dans l'application.
4. Acceptez **Autoriser le débogage USB ?** sur le téléphone et cochez *Toujours autoriser sur cet ordinateur*.

Une fois terminé, le dernier écran désactive de nouveau le débogage.

## Comment elle reste sûre

- Seules les applications d'une liste vérifiée ([`shared/catalog.json`](shared/catalog.json)) sont proposées.
- Jamais proposés, quoi que dise la liste : les applications Téléphone et SMS par défaut, toute
  application pouvant servir d'écran d'accueil, le clavier, l'application qui gère un profil professionnel ou un téléphone d'entreprise, les Paramètres, le Play Store, les services
  Google Play, WebView, la téléphonie, le Bluetooth, le NFC, les alertes d'urgence et le cœur d'Android
  (la section `keep` de la liste et une liste intégrée).
- Chaque changement est inscrit dans une sauvegarde avec sa valeur d'origine *avant* d'être fait :
  même un passage interrompu peut être annulé.
- Les sauvegardes sont dans `%LOCALAPPDATA%\UnbloatMyPhone\backups` (Mac :
  `~/Library/Application Support/UnbloatMyPhone/backups`, Linux : `~/.local/share/UnbloatMyPhone/backups`),
  avec un instantané brut de tous les paquets et réglages. Même format sur tous les systèmes.

## Confidentialité

L'application n'a ni compte, ni statistiques, ni serveur. En plus de votre téléphone, elle ne contacte que :
- `dl.google.com`, une fois, pour télécharger les outils ADB de Google ;
- `github.com` pour vérifier s'il existe une nouvelle version (désactivable dans la fenêtre de mise à
  jour) et récupérer la dernière liste d'applications ;
- la page « nouveau ticket » de GitHub dans votre navigateur, seulement si vous cliquez sur **Les
  proposer sur GitHub**, avec le modèle du téléphone et les noms d'applications préremplis pour relecture.

## Pour les développeurs

Voir la [version anglaise](README.md#for-developers).

## Licence

MIT. À vos risques : l'application ne fait que désactiver et réactiver, mais c'est votre téléphone.
