const FENIX_END_REMASTERED_EYES = [
  'endrem:old_eye',
  'endrem:rogue_eye',
  'endrem:nether_eye',
  'endrem:cold_eye',
  'endrem:corrupted_eye',
  'endrem:magical_eye',
  'endrem:black_eye',
  'endrem:lost_eye',
  'endrem:wither_eye',
  'endrem:guardian_eye',
  'endrem:witch_eye',
  'endrem:cursed_eye',
  'endrem:exotic_eye',
  'endrem:evil_eye',
  'endrem:undead_eye',
  'endrem:cryptic_eye'
]

function fenixGrantOpenEndPortal(player) {
  const name = player.username || player.name.getString()
  player.server.runCommandSilent('advancement grant ' + name + ' only fenix_end_eyes:open_end_portal')
}

function fenixHasEndPortalNear(level, x, y, z) {
  for (let dx = -4; dx <= 4; dx++) {
    for (let dz = -4; dz <= 4; dz++) {
      if (level.getBlock(x + dx, y, z + dz).id == 'minecraft:end_portal') {
        return true
      }
    }
  }
  return false
}

BlockEvents.rightClicked('minecraft:end_portal_frame', event => {
  if (event.level.clientSide) return
  if (!event.player) return
  if (!event.item || FENIX_END_REMASTERED_EYES.indexOf(event.item.id) == -1) return

  const player = event.player
  const level = event.level
  const pos = event.block.pos

  event.server.scheduleInTicks(5, { player: player, level: level, x: pos.x, y: pos.y, z: pos.z }, ctx => {
    const data = ctx.data
    if (fenixHasEndPortalNear(data.level, data.x, data.y, data.z)) {
      fenixGrantOpenEndPortal(data.player)
    }
  })
})
