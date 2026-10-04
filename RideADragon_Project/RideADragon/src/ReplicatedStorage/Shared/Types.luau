--[[
	Types
	Shared data shapes. Server data is the source of truth; the client holds
	a read-only mirror kept in sync by DataSync.
]]

export type DragonRecord = {
	UniqueId: string,
	SpeciesId: string,
	Name: string,
	Rarity: string,
	Level: number,
	XP: number,
	Mutation: string, -- "None" | "Shiny" | "Golden" | "Shadow" | "Rainbow"
	Speed: number,
	FlightSpeed: number,
	IncomePerSecond: number,
	Locked: boolean,
	PlacedNestId: string, -- "" when not placed, otherwise nest index as string
	CreatedAt: number,
}

export type EggRecord = {
	Id: string,
	Type: string,
	FoundAt: number,
}

export type RequestResult = {
	ok: boolean,
	err: string?,
	msg: string?,
	data: any?,
}

return {}
