package com.edde746.plezy.games

/** Emulator ports are independent of Android's numbering (TV virtual remotes use it too). */
internal class GameControllerPorts {
    private val ports = mutableMapOf<Int, Int>()

    fun update(connectedGamepads: List<Int>): Set<Int> {
        val disconnected = ports.keys.filter { it !in connectedGamepads }
        val released = disconnected.mapNotNull { ports.remove(it) }.toSet()
        for (id in connectedGamepads.sorted()) {
            if (id !in ports) {
                val free = (0..3).firstOrNull { it !in ports.values } ?: break
                ports[id] = free
            }
        }
        return released
    }

    /** Remotes/keyboards share player one; extra gamepads must never reach native port arrays. */
    fun port(deviceId: Int, isGamepad: Boolean): Int? = if (isGamepad) ports[deviceId] else 0
}
