package main

import "github.com/devarminas/marque/server/internal/wire"

func main() {
	id := wire.NpcId{Index: 1, Gen: 1}
	_, _ = wire.Hp{Id: id, Hp: 1, MaxHp: 1}.Append(nil)
}
