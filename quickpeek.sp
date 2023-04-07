#include <sourcemod>
#include <dhooks>
#include <clientprefs>

#define JL_OPCODE 0x8c
#define JNZ_OPCODE 0x85
#define NOP_OPCODE 0x90
#define CALL_OPCODE 0xff

#define ACT_VM_PRIMARYATTACK 180
#define EF_NODRAW 32

public Plugin myinfo = {
	name = "QuickPeek",
	author = "VerMon",
	description = "Observe other players' actions while in-game",
	version = "1.0.0",
	url = "https://steamcommunity.com/profiles/76561198141196062"
}

enum {
	ACTION_NONE,
	ACTION_START,
	ACTION_STOP,
	ACTION_NEXT_TARGET,
	ACTION_PREV_TARGET,
	ACTION_NEXT_TARGET_OR_STOP
}

enum struct Offsets {
	int base_player_delay;
	int base_player_replay_end;
	int base_player_replay_entity;
	int base_client_entity_index;
	int base_client_delta_tick;
	int game_client_send_sound_jnz;
	int base_player_spawn_stop_replay_mode_call;
}

Offsets offsets;

Handle sync_hud;

Handle get_client;
Handle free_base_lines;
Handle send_weapon_anim;

char stop_replay_mode_call[6];

ConVar sv_minupdaterate;

float player_data_spec_update_time[MAXPLAYERS + 1];
float player_data_hud_update_time[MAXPLAYERS + 1];
int player_data_spec_target[MAXPLAYERS + 1];
int player_data_old_buttons[MAXPLAYERS + 1];
int player_data_queue_action[MAXPLAYERS + 1];
bool player_data_block_angles[MAXPLAYERS + 1];

public void OnPluginStart() {
	GameData game_data = LoadGameConfigFile("quickpeek.games");
	load_offsets(game_data);

	int send_sound = view_as<int>(game_data.GetMemSig("game_client_send_sound"));
	StoreToAddress(view_as<Address>(send_sound + offsets.game_client_send_sound_jnz), JL_OPCODE, NumberType_Int8, true);

	int spawn_player = view_as<int>(game_data.GetMemSig("base_player_spawn"));
	
	for (int i = 0; i < 6; ++i) {
		stop_replay_mode_call[i] = LoadFromAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), NumberType_Int8);
		StoreToAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), NOP_OPCODE, NumberType_Int8, true);
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(game_data, SDKConf_Signature, "base_client_free_baselines");
	free_base_lines = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Server);
	PrepSDKCall_SetFromConf(game_data, SDKConf_Virtual, "base_server_get_client");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
	get_client = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(game_data, SDKConf_Virtual, "base_combat_weapon_send_weapon_anim");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	send_weapon_anim = EndPrepSDKCall();

	ConVar sv_maxreplay = FindConVar("sv_maxreplay");
	sv_maxreplay.FloatValue = 1.0;

	sv_minupdaterate = FindConVar("sv_minupdaterate");

	RegConsoleCmd("qpeek", quickpeek_console_command);

	AddCommandListener(hold_quickpeek_command_listener, "+qpeek");
	AddCommandListener(unhold_quickpeek_command_listener, "-qpeek")

	RegClientCookie("quickpeek_block_angles", "Block angles change during observation", CookieAccess_Protected);

	HookEvent("player_death", player_death_event, EventHookMode_Post);

	sync_hud = CreateHudSynchronizer();

	if (IsServerProcessing())
		for (int i = 1; i <= MaxClients; ++i)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
}

public void OnPluginEnd() {
	for (int i = 1; i <= MaxClients; ++i)
		if (IsClientInGame(i) && IsPlayerAlive(i)) {
			int replay_entity = GetEntData(i, offsets.base_player_replay_entity, 4);

			if (replay_entity)
				stop_spectating(i);
		}

	GameData game_data = LoadGameConfigFile("quickpeek.games");

	int send_sound = view_as<int>(game_data.GetMemSig("game_client_send_sound"));
	StoreToAddress(view_as<Address>(send_sound + offsets.game_client_send_sound_jnz), JNZ_OPCODE, NumberType_Int8, true);

	int spawn_player = view_as<int>(game_data.GetMemSig("base_player_spawn"));

	for (int i = 0; i < 6; ++i)
		StoreToAddress(view_as<Address>(spawn_player + offsets.base_player_spawn_stop_replay_mode_call + i), stop_replay_mode_call[i], NumberType_Int8, true);	
}

public void OnClientPutInServer(int index) {
	player_data_spec_target[index] = 1;
	player_data_spec_update_time[index] = 0.0;
	player_data_hud_update_time[index] = 0.0;
	player_data_old_buttons[index] = 0;
	player_data_queue_action[index] = ACTION_NONE;

	if (!AreClientCookiesCached(index))
		player_data_block_angles[index] = true;
}

public void OnClientCookiesCached(int index) {
	Cookie cookie = FindClientCookie("quickpeek_block_angles");

	char buf[4];
	GetClientCookie(index, cookie, buf, sizeof(buf));

	if (strlen(buf) == 0)
		IntToString(1, buf, sizeof(buf));

	player_data_block_angles[index] = view_as<bool>(StringToInt(buf));
}

public void OnClientDisconnect(int index) {
	int client = SDKCall(get_client, index - 1) - 4;
	StoreToAddress(view_as<Address>(client + offsets.base_client_entity_index), index, NumberType_Int32, false);
	stop_other_spectating_request(index);
}

public Action OnPlayerRunCmd(int index, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& sub_type, int& cmd_num, int& tick_count, int& seed, int mouse[2]) {
	if (!IsPlayerAlive(index))
		return Plugin_Continue;

	int replay_entity = GetEntData(index, offsets.base_player_replay_entity, 4);

	if (!replay_entity)
		return Plugin_Continue;

	int action = ACTION_NONE;
	
	if (buttons & IN_ATTACK && (player_data_old_buttons[index] & IN_ATTACK == 0))
		action = ACTION_NEXT_TARGET;
	else if (buttons & IN_ATTACK2 && (player_data_old_buttons[index] & IN_ATTACK2 == 0))
		action = ACTION_PREV_TARGET;

	if (action != ACTION_NONE) {
		int target = cycle_target(index, player_data_spec_target[index], false, action != ACTION_NEXT_TARGET);

		if (target) {
			if (!is_spec_update_available(index))
				player_data_queue_action[index] = action;
			else
				switch_spec_target(index, target);
		}
	}

	player_data_old_buttons[index] = buttons;
	
	buttons &= ~IN_ATTACK;
	buttons &= ~IN_ATTACK2;

	weapon = 0;

	if (player_data_block_angles[index]) {
		GetClientEyeAngles(index, angles);
		TeleportEntity(index, NULL_VECTOR, angles, NULL_VECTOR);
	}

	return Plugin_Continue;
}

public void OnGameFrame() {
	for (int i = 1; i <= MaxClients; ++i) {
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;

		if (is_spec_update_available(i)) {
			switch (player_data_queue_action[i]) {
				case ACTION_START: {
					int target = cycle_target(i, player_data_spec_target[i], true, false);
					if (target)
						start_spectating(i, target);
				}

				case ACTION_STOP:
					stop_spectating(i);

				case ACTION_NEXT_TARGET: {
					int target = cycle_target(i, player_data_spec_target[i], false, false);
					if (target)
						switch_spec_target(i, target);
				}

				case ACTION_PREV_TARGET: {
					int target = cycle_target(i, player_data_spec_target[i], false, true);
					if (target)
						switch_spec_target(i, target);
				}

				case ACTION_NEXT_TARGET_OR_STOP: {
					int target = cycle_target(i, player_data_spec_target[i], true, false);
					if (target)
						switch_spec_target(i, target);
					else
						stop_spectating(i);
				}
			}

			player_data_queue_action[i] = ACTION_NONE;
		}

		int replay_entity = GetEntData(i, offsets.base_player_replay_entity, 4);
		
		if (replay_entity && (GetGameTime() >= player_data_hud_update_time[i]) && (player_data_queue_action[i] != ACTION_NEXT_TARGET_OR_STOP)) {
			char buf[MAX_NAME_LENGTH];
			GetClientName(replay_entity, buf, sizeof(buf));
			
			SetHudTextParams(-1.0, 0.65, 1.05, 255, 255, 255, 0, 0, 0.0, 0.0, 0.0);
			ShowSyncHudText(i, sync_hud, buf);

			player_data_hud_update_time[i] = GetGameTime() + 1.0;
		}
	}
}

Action quickpeek_console_command(int index, int args) {
	if (args > 0) {
		char buf[16];
		GetCmdArg(1, buf, sizeof(buf));

		if (strcmp(buf, "angles", false) == 0) {
			player_data_block_angles[index] = !player_data_block_angles[index];

			Cookie cookie = FindClientCookie("quickpeek_block_angles");
			cookie.Set(index, player_data_block_angles[index] ? "1" : "0");

			return Plugin_Handled;
		}

		return Plugin_Continue;
	}
	
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	int replay_entity = GetEntData(index, offsets.base_player_replay_entity, 4);

	if (is_spec_update_available(index)) {
		if (replay_entity)
			stop_spectating(index);
		else {
			int target = cycle_target(index, player_data_spec_target[index], true, false);
			if (!target)
				return Plugin_Handled;

			start_spectating(index, target);
		}
	}
	else if (replay_entity)
		player_data_queue_action[index] = ACTION_STOP;
	else if (cycle_target(index, player_data_spec_target[index], true, false))
		player_data_queue_action[index] = ACTION_START;
	
	return Plugin_Handled;
}

Action hold_quickpeek_command_listener(int index, const char[] command, int args) {
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	int replay_entity = GetEntData(index, offsets.base_player_replay_entity, 4);

	if (replay_entity)
		return Plugin_Handled;

	if (!is_spec_update_available(index)) {
		player_data_queue_action[index] = ACTION_START;
		return Plugin_Handled;
	}

	int target = cycle_target(index, player_data_spec_target[index], true, false);
	if (!target)
		return Plugin_Handled;

	start_spectating(index, target);

	return Plugin_Handled;
}

Action unhold_quickpeek_command_listener(int index, const char[] command, int args) {
	if (!IsPlayerAlive(index))
		return Plugin_Handled;

	if (player_data_queue_action[index] == ACTION_START)
		player_data_queue_action[index] = ACTION_NONE;

	int replay_entity = GetEntData(index, offsets.base_player_replay_entity, 4);

	if (!replay_entity)
		return Plugin_Handled;

	if (!is_spec_update_available(index)) {
		player_data_queue_action[index] = ACTION_STOP;
		return Plugin_Handled;
	}

	stop_spectating(index);
	
	return Plugin_Handled;
}

void player_death_event(Event event, const char[] name, bool dont_broadcast) {
	int user_id = event.GetInt("userid");
	int index = GetClientOfUserId(user_id);

	int replay_entity = GetEntData(index, offsets.base_player_replay_entity, 4);

	if (replay_entity) {
		if (is_spec_update_available(index))
			stop_spectating(index);
		else
			player_data_queue_action[index] = ACTION_STOP;
	}

	stop_other_spectating_request(index);
}

static bool is_spec_update_available(int index) {
	return GetGameTime() >= player_data_spec_update_time[index];
}

static bool is_valid_spec_target(int index) {
	if (IsFakeClient(index) || !IsPlayerAlive(index) || GetEntProp(index, Prop_Send, "m_fEffects") & EF_NODRAW)
		return false;

	return true;
}

static int bound_player_index(int index) {
	if (index > MaxClients)
		return 1;

	if (index < 1)
		return MaxClients;

	return index;
}

static float spec_update_time(int index) {
	return GetClientAvgLatency(index, NetFlow_Outgoing) * 2.0 + 1.0 / sv_minupdaterate.FloatValue * 10.0;
}

static int cycle_target(int index, int start_index, bool check_first, bool reverse) {
	// {0, 1} -> {1, -1}
	int step = 1 - 2 * view_as<int>(reverse);
	
	int search_index = bound_player_index(start_index + view_as<int>(check_first) * -step);
	int end_index = bound_player_index(start_index + -step);
	
	do {
		search_index = bound_player_index(search_index + step);

		if (search_index == index)
			continue;

		if (IsClientInGame(search_index) && is_valid_spec_target(search_index))
			return search_index			
	} while (search_index != end_index)

	return 0;
}

static void start_spectating(int index, int target) {
	SetEntDataFloat(index, offsets.base_player_delay, 0.01);
	SetEntDataFloat(index, offsets.base_player_replay_end, 9999999.0);
	SetEntData(index, offsets.base_player_replay_entity, target, 4, false);

	kill_cam_message(index, 4, target, index);
	fix_spec_weapon_anim(target);
	
	int client = SDKCall(get_client, index - 1) - 4;

	SDKCall(free_base_lines, view_as<Address>(client));

	player_data_spec_target[index] = target;
	player_data_spec_update_time[index] = GetGameTime() + spec_update_time(index);
	player_data_hud_update_time[index] = 0.0;
	player_data_queue_action[index] = ACTION_NONE;
}

static void stop_spectating(int index) {
	SetEntDataFloat(index, offsets.base_player_delay, 0.0, false);
	SetEntDataFloat(index, offsets.base_player_replay_end, -1.0, false);
	SetEntData(index, offsets.base_player_replay_entity, 0, 4, false);

	kill_cam_message(index, 0, 0, 0);

	int client = SDKCall(get_client, index - 1) - 4;
	SDKCall(free_base_lines, client);

	ShowSyncHudText(index, sync_hud, "");
	
	player_data_spec_update_time[index] = GetGameTime() + spec_update_time(index);
}

static void switch_spec_target(int index, int target) {
	SetEntData(index, offsets.base_player_replay_entity, target, 4, false);

	kill_cam_message(index, 4, target, index);
	fix_spec_weapon_anim(target);

	int client = SDKCall(get_client, index - 1) - 4;
	StoreToAddress(view_as<Address>(client + offsets.base_client_delta_tick), -1, NumberType_Int32, false);
	SDKCall(free_base_lines, client);

	player_data_spec_target[index] = target;
	player_data_spec_update_time[index] = GetGameTime() + spec_update_time(index);
	player_data_hud_update_time[index] = 0.0;
}

static void stop_other_spectating_request(int index) {
	for (int i = 1; i <= MaxClients; ++i) {
		if (IsClientInGame(i) && IsPlayerAlive(i)) {
			int replay_entity = GetEntData(i, offsets.base_player_replay_entity, 4);

			if (index == replay_entity) {
				if (is_spec_update_available(i)) {
					int target = cycle_target(i, replay_entity, false, false);
					
					if (target)
						switch_spec_target(i, target);
					else
						stop_spectating(i);
				}
				else
					player_data_queue_action[i] = ACTION_NEXT_TARGET_OR_STOP;
			}
		}
	}
}

static void kill_cam_message(int index, int mode, int first, int second) {
	BfWrite bf = view_as<BfWrite>(StartMessageOne("KillCam", index, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS));
	bf.WriteByte(mode);
	bf.WriteByte(first);
	bf.WriteByte(second);
	EndMessage();
}

static fix_spec_weapon_anim(int index) {
	int active_weapon = GetEntPropEnt(index, Prop_Send, "m_hActiveWeapon");
	if (active_weapon != -1) {
		int sequence = GetEntProp(active_weapon, Prop_Send, "m_nSequence");
		if (sequence == 6 || sequence == 14)
			SDKCall(send_weapon_anim, active_weapon, ACT_VM_PRIMARYATTACK);
	}
}

static void load_offsets(GameData gd) {
	offsets.base_player_delay = gd.GetOffset("base_player_delay");
	// we assume other variables are near
	offsets.base_player_replay_end = offsets.base_player_delay + 0x4;
	offsets.base_player_replay_entity = offsets.base_player_replay_end + 0x4;

	offsets.base_client_entity_index = gd.GetOffset("base_client_entity_index");
	offsets.base_client_delta_tick = gd.GetOffset("base_client_delta_tick");

	offsets.game_client_send_sound_jnz = gd.GetOffset("game_client_send_sound_jnz");
	offsets.base_player_spawn_stop_replay_mode_call = gd.GetOffset("base_player_spawn_stop_replay_mode_call");
}
