package main

import "core:fmt"

Player :: struct {
	id:   int,
	hp:   f32,
	xp:   f32,
}

main :: proc() {
	memory: Memory_System
	memory_system_initialize(&memory)
    defer memory_system_shutdown(&memory)

	player, _ := new(Player, memory.app_allocator)

	if player != nil {
		player.id = 1
		player.hp = 100
		player.xp = 0
	}

    fmt.println("Player: {}", player)
}
