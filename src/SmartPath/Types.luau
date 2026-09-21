--!strict
-- Types.luau
-- Tipos compartilhados da SmartPath. Este módulo não
-- expõe valores de runtime além de uma tabela vazia — `export type` é a única razão
-- dele existir.

export type SmartAction = "Walk" | "Jump" | "Drop" | "Link"

export type Waypoint = {
	Position: Vector3,
	Action: Enum.PathWaypointAction,
	Label: string,
	SmartAction: SmartAction?,
	JumpHeight: number?,
}

export type IndoorOptions = {
	AdaptiveRadius: boolean?,
	MinRadius: number?,
	RadiusSteps: { number }?,
}

export type JumpOptions = {
	Enabled: boolean?,
	Mode: ("Native" | "Injected")?,
	MaxHeight: number?,
	DetourRatio: number?,
}

export type StabilityOptions = {
	Cache: boolean?,
	Smoothing: boolean?,
	Hysteresis: number?,
	Curves: boolean?,
}

export type GeometryOptions = {
	AutoFilter: boolean?,
	RequireNameMatch: boolean?,
}

export type AgentOptions = {
	Radius: number?,
	Height: number?,
	WalkSpeed: number?,
}

export type SchedulerOptions = {
	Priority: number?,
}

-- Tabela de opções. Todo campo é opcional; `nil` sempre significa
-- "derive do personagem ou use o default" (zero configuração obrigatória).
export type Options = {
	Indoor: IndoorOptions?,
	Jump: JumpOptions?,
	Stability: StabilityOptions?,
	Geometry: GeometryOptions?,
	Agent: AgentOptions?,
	Scheduler: SchedulerOptions?,
	Debug: boolean?,
}

-- Options já resolvido por Config.resolve: todo campo preenchido.
export type ResolvedOptions = {
	Indoor: {
		AdaptiveRadius: boolean,
		MinRadius: number,
		RadiusSteps: { number },
	},
	Jump: {
		Enabled: boolean,
		Mode: "Native" | "Injected",
		MaxHeight: number?,
		DetourRatio: number,
	},
	Stability: {
		Cache: boolean,
		Smoothing: boolean,
		Hysteresis: number,
		Curves: boolean,
	},
	Geometry: {
		AutoFilter: boolean,
		RequireNameMatch: boolean,
	},
	Agent: {
		Radius: number,
		Height: number,
		WalkSpeed: number,
	},
	Scheduler: {
		Priority: number,
	},
	Debug: boolean,
}

export type AgentState = "Idle" | "Following" | "DirectJump" | "Airborne" | "Failed"

-- aceito onde a API pede um personagem: normalizado internamente por Util.
export type CharacterLike = Model | Humanoid | BasePart

-- aceito onde a API pede um destino.
export type TargetLike = Vector3 | BasePart | Model

return {}
