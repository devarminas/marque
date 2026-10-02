package main

import "github.com/devarminas/marque/server/internal/wire"

func main() {
	id := wire.NpcId{Index: 1, Gen: 1}
	v, _ := wire.HpFields{Id: id, Hp: 1, MaxHp: 1}.Build()
	_ = v.Hp()
}
