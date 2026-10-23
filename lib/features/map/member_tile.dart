import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../domain/ride_logic.dart';

/// Compact rider row used on the map panel, home card and waiting room.
class MemberTile extends StatelessWidget {
  const MemberTile({
    super.key,
    required this.member,
    required this.location,
    required this.now,
    this.myPoint,
    this.isMe = false,
    this.farFromGroup = false,
    this.dense = false,
    this.onTap,
    this.trailing,
  });

  final RideMember member;
  final LiveLocation? location;
  final DateTime now;
  final Coord? myPoint;
  final bool isMe;
  final bool farFromGroup;
  final bool dense;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final status = statusOf(location, now);
    final loc = location;
    final parts = <String>[
      status.label,
      if (loc != null && !status.isLive) 'last seen ${ago(loc.updatedAt, now)}',
      if (loc != null && status.isLive) ago(loc.updatedAt, now),
      if (!isMe && loc != null && myPoint != null) '≈ ${formatDistance(distanceMeters(myPoint!, loc.point))}',
    ];
    return ListTile(
      dense: dense,
      contentPadding: dense ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 16),
      onTap: onTap,
      leading: RiderAvatar(
        uid: member.uid,
        name: member.name,
        photoUrl: member.photoUrl,
        status: status,
        radius: dense ? 16 : 22,
      ),
      title: Row(
        children: [
          Flexible(child: Text(isMe ? '${member.name} (you)' : member.name, overflow: TextOverflow.ellipsis)),
          if (member.isOwner) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.star, size: 16)),
          if (farFromGroup)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.warning_amber, size: 18, color: Color(0xFFEF6C00), semanticLabel: 'Far from group'),
            ),
        ],
      ),
      subtitle: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
