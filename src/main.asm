INCLUDE "hardware.inc"

DEF MAP_SIZE EQU 180

SECTION "VBlank Interrupt", ROM0[$0040]
VBlankInterrupt:
	push af
	push bc
	push de
	push hl
	jp VBlankHandler

SECTION "Header", ROM0[$100]

    jp EntryPoint

    ds $150 - @, 0 ; Make room for the header

EntryPoint:
    ; Do not turn the LCD off outside of VBlank
WaitVBlank:
    ld a, [rLY]
    cp 144
    jp c, WaitVBlank

    ; Turn the LCD off
    ld a, 0
    ld [rLCDC], a

    ; Copy the tile data
    ld de, Tiles
    ld hl, $9000
    ld bc, TilesEnd - Tiles
    call Memcopy

    ; Copy the initial tilemap
    ld de, Tilemap
    ld hl, $9800
    ld bc, TilemapEnd - Tilemap
    call Memcopy

    ; Choose and draw the map tiles
    call Random ; Get a random number into A
    and 1 ; Check the least significant bit
    call DrawMap

    ; Copy the player tile
    ld de, Player
    ld hl, $8000
    ld bc, PlayerEnd - Player
    call Memcopy

    ld a, 0
    ld b, 160
    ld hl, _OAMRAM
ClearOam:
    ld [hli], a
    dec b
    jp nz, ClearOam

    ; Initialize the player sprite in OAM
    ld hl, _OAMRAM
    ld a, 128 + 16
    ld [hli], a
    ld a, 16 + 8
    ld [hli], a
    ld a, 0
    ld [hli], a
    ld [hli], a

    ; Turn the LCD on
    ld a, LCDCF_ON | LCDCF_BGON | LCDCF_OBJON
    ld [rLCDC], a

    ; During the first (blank) frame, initialize display registers
    ld a, %11100100
    ld [rBGP], a
    ld a, %11100100
    ld [rOBP0], a

    ; Initialize global variables
    xor a
    ld [wFrameCounter], a
    ld [wCurKeys], a
    ld [wNewKeys], a

    ; Initialize the random seed
    ld a, [$FF04]   ; Get DIV upper byte
    ld b, a         ; put it in B
    ld a, [$FF05]   ; Get DIV lower byte
    xor a, b        ; XOR the lower byte with the upper byte
    ld [wRandomSeed], a    ; Store it in the seed variable

Main:
    ; Wait until it's *not* VBlank
    ld a, [rLY]
    cp 144
    jp nc, Main
WaitVBlank2:
    ld a, [rLY]
    cp 144
    jp c, WaitVBlank2

    ld a, [wFrameCounter]
    inc a
    ld [wFrameCounter], a
    cp a, 6 ; Every 6 frames (10 times per second), run the following code
    jp nz, Main

    ; Reset the frame counter back to 0
    ld a, 0
    ld [wFrameCounter], a

    ; Check the current keys every frame and move left or right.
    call UpdateKeys

    ; First, check if the left button is pressed.
CheckLeft:
    ld a, [wCurKeys]
    and a, PADF_LEFT
    jp z, CheckRight
Left:
    call TogglePlayerSprite
    call GetPlayerTileByPixel
    dec l
    ld a, [hl]
    call IsWallTile
    jp z, Main
    ; Move the player one tile to the left.
    ld a, [_OAMRAM + 1]
    sub a, 8
    ld [_OAMRAM + 1], a
    jp Main

    ; Then check the right button.
CheckRight:
    ld a, [wCurKeys]
    and a, PADF_RIGHT
    jp z, CheckDown
Right:
    call TogglePlayerSprite
    call GetPlayerTileByPixel
    inc l
    ld a, [hl]
    call IsWallTile
    jp z, Main
    ; Move the player one pixel to the right.
    ld a, [_OAMRAM + 1]
    add a, 8
    ld [_OAMRAM + 1], a
    jp Main

CheckDown:
    ld a, [wCurKeys]
    and a, PADF_DOWN
    jp z, CheckUp
Down:
    call TogglePlayerSprite
    call GetPlayerTileByPixel
    ld bc, 32 ; Add one row
    add hl, bc
    ld a, [hl]
    call IsWallTile
    jp z, Main
    ; Move the player one tile to the left.
    ld a, [_OAMRAM]
    add a, 8
    ld [_OAMRAM], a
    jp Main

CheckUp:
    ld a, [wCurKeys]
    and a, PADF_UP
    jp z, Main
Up:
    call TogglePlayerSprite
    call GetPlayerTileByPixel
    ld bc, -32 ; Substract one row
    add hl, bc
    ld a, [hl]
    call IsWallTile
    jp z, Main
    ; Move the player one tile to the left.
    ld a, [_OAMRAM]
    sub a, 8
    ld [_OAMRAM], a
    jp Main

UpdateKeys:
    ; Poll half the controller
    ld a, P1F_GET_BTN
    call .onenibble
    ld b, a ; B7-4 = 1; B3-0 = unpressed buttons
    
    ; Poll the other half
    ld a, P1F_GET_DPAD
    call .onenibble
    swap a ; A3-0 = unpressed directions; A7-4 = 1
    xor a, b ; A = pressed buttons + directions
    ld b, a ; B = pressed buttons + directions
    
    ; And release the controller
    ld a, P1F_GET_NONE
    ldh [rP1], a
    
    ; Combine with previous wCurKeys to make wNewKeys
    ld a, [wCurKeys]
    xor a, b ; A = keys that changed state
    and a, b ; A = keys that changed to pressed
    ld [wNewKeys], a
    ld a, b
    ld [wCurKeys], a
    ret
    
    .onenibble
    ldh [rP1], a ; switch the key matrix
    call .knownret ; burn 10 cycles calling a known ret
    ldh a, [rP1] ; ignore value while waiting for the key matrix to settle
    ldh a, [rP1]
    ldh a, [rP1] ; this read counts
    or a, $F0 ; A7-4 = 1; A3-0 = unpressed keys
    .knownret
    ret

; Toggle the player sprite tile number between 0 and 1.
TogglePlayerSprite:
    push hl
    push af
    ld hl, _OAMRAM+2
    ld a, [hl]
    xor 1
    ld [hl], a
    pop af
    pop hl
    ret

; Copy bytes from one area to another.
; @param a: Index of map to draw
DrawMap:
    push af
    push bc
    push hl
    ld hl, Map1 - MAP_SIZE
    ld de, MAP_SIZE
    inc a ; TODO: move this to generating random number between 1 and 2 in stead of 0 and 1
MapIncreaseLoop:
    add hl, de ; add a map size (next map)
    dec a ; decrease counter
    jr nz, MapIncreaseLoop
    ld d, h ; swap de and hl
    ld e, l
    ld hl, $9821 ; start at (1,1)
    ld b, 16 ; rows
RowLoop:
    ld c, 12 ; tiles per row
TileLoop:
    ld a, [de]
    ld [hli], a
    inc de
    dec c
    jr nz, TileLoop

    ; wrap to the next line
    push bc
    ld bc, 20
    add hl, bc
    pop bc

    dec b
    jr nz, RowLoop

    pop hl   ; Restore HL
    pop bc
    pop af
    ret

; Returns a random number (LFSR) in A (0-255)
Random:
    ld a, [wRandomSeed]  ; Load the current seed value
    rra           ; Rotate right through carry
    jr nc, NoCarry
    xor a, $2D   ; XOR with a magic number if carry was set
NoCarry:
    ld [wRandomSeed], a  ; Store the new seed value
    ret

; Copy bytes from one area to another.
; @param de: Source
; @param hl: Destination
; @param bc: Length
Memcopy:
    ld a, [de]
    ld [hli], a
    inc de
    dec bc
    ld a, b
    or a, c
    jp nz, Memcopy
    ret

; Gets the tile address of the player sprite based on its pixel position.
; @changes bc, a
; @return hl: tile address
GetPlayerTileByPixel:
	ld a, [_OAMRAM]
	sub a, 16 - 1
	ld c, a
	ld a, [_OAMRAM + 1]
	sub a, 8
	ld b, a
	call GetTileByPixel
	ret

; hl = $9800 + X + Y * 32
; @param b: X
; @param c: Y
; @return hl: tile address
GetTileByPixel:
	; First, we need to divide by 8 to convert a pixel position to a tile position.
	; After this we want to multiply the Y position by 32.
	; These operations effectively cancel out so we only need to mask the Y value.
	ld a, c
	and a, %11111000
	ld l, a
	ld h, 0
	; Now we have the position * 8 in hl
	add hl, hl ; position * 16
	add hl, hl ; position * 32
	; Convert the X position to an offset.
	ld a, b
	srl a ; a / 2
	srl a ; a / 4
	srl a ; a / 8
	; Add the two offsets together.
	add a, l
	ld l, a
	adc a, h
	sub a, l
	ld h, a
	; Add the offset to the tilemap's base address, and we are done!
	ld bc, $9800
	add hl, bc
	ret

; @param a: tile ID
; @return z: set if a is a wall.
IsWallTile:
    cp a, $00
    ret z
    cp a, $01
    ret z
    cp a, $02
    ret z
    cp a, $04
    ret z
    cp a, $05
    ret z
    cp a, $06
    ret z
    cp a, $07
    ret z
    cp a, $09
    ret

SECTION "VBlank Handler", ROM0
VBlankHandler:
	; Now we just have to `pop` those registers and return!
	pop hl
	pop de
	pop bc
	pop af
	reti

Tiles:
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33322222
    dw `33322222
    dw `33322222
    dw `33322211
    dw `33322211
    dw `33333333
    dw `33333333
    dw `33333333
    dw `22222222
    dw `22222222
    dw `22222222
    dw `11111111
    dw `11111111
    dw `33333333
    dw `33333333
    dw `33333333
    dw `22222333
    dw `22222333
    dw `22222333
    dw `11222333
    dw `11222333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33333333
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `33322211
    dw `22222222
    dw `20000000
    dw `20111111
    dw `20111111
    dw `20111111
    dw `20111111
    dw `22222222
    dw `33333333
    dw `22222223
    dw `00000023
    dw `11111123
    dw `11111123
    dw `11111123
    dw `11111123
    dw `22222223
    dw `33333333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `11222333
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `00000000
    dw `11001100
    dw `11111111
    dw `11111111
    dw `21212121
    dw `22222222
    dw `22322232
    dw `23232323
    dw `33333333
    ; Paste your logo here:
    dw `33000000
    dw `33000000
    dw `33000000
    dw `33000000
    dw `33111100
    dw `33111100
    dw `33111111
    dw `33111111
    dw `33331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `00331111
    dw `11331111
    dw `11331111
    dw `11333300
    dw `11113300
    dw `11113300
    dw `11113300
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `00003333
    dw `00000033
    dw `00000033
    dw `00000033
    dw `11000033
    dw `11000033
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11113311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `33111111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11331111
    dw `11330000
    dw `11330000
    dw `11330000
    dw `33330000
    dw `11113311
    dw `11113311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00003311
    dw `00333311
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11111133
    dw `11113333
    ; digits
    ; 0
    dw `33333333
    dw `33000033
    dw `30033003
    dw `30033003
    dw `30033003
    dw `30033003
    dw `33000033
    dw `33333333
    ; 1
    dw `33333333
    dw `33300333
    dw `33000333
    dw `33300333
    dw `33300333
    dw `33300333
    dw `33000033
    dw `33333333
    ; 2
    dw `33333333
    dw `33000033
    dw `30330003
    dw `33330003
    dw `33000333
    dw `30003333
    dw `30000003
    dw `33333333
    ; 3
    dw `33333333
    dw `30000033
    dw `33330003
    dw `33000033
    dw `33330003
    dw `33330003
    dw `30000033
    dw `33333333
    ; 4
    dw `33333333
    dw `33000033
    dw `30030033
    dw `30330033
    dw `30330033
    dw `30000003
    dw `33330033
    dw `33333333
    ; 5
    dw `33333333
    dw `30000033
    dw `30033333
    dw `30000033
    dw `33330003
    dw `30330003
    dw `33000033
    dw `33333333
    ; 6
    dw `33333333
    dw `33000033
    dw `30033333
    dw `30000033
    dw `30033003
    dw `30033003
    dw `33000033
    dw `33333333
    ; 7
    dw `33333333
    dw `30000003
    dw `33333003
    dw `33330033
    dw `33300333
    dw `33000333
    dw `33000333
    dw `33333333
    ; 8
    dw `33333333
    dw `33000033
    dw `30333003
    dw `33000033
    dw `30333003
    dw `30333003
    dw `33000033
    dw `33333333
    ; 9
    dw `33333333
    dw `33000033
    dw `30330003
    dw `30330003
    dw `33000003
    dw `33330003
    dw `33000033
    dw `33333333
TilesEnd:

Tilemap:
; Game map window is 12x16 starting at (1,1)
; Score at (3,16)-(3,17)
    db $00, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $01, $02, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $1A, $1A, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $0A, $0B, $0C, $0D, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $0E, $0F, $10, $11, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $12, $13, $14, $15, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $07, $03, $16, $17, $18, $19, $03, 0,0,0,0,0,0,0,0,0,0,0,0
    db $04, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $09, $07, $03, $03, $03, $03, $03, $03, 0,0,0,0,0,0,0,0,0,0,0,0
TilemapEnd:

Map1:
    db $01, $01, $01, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $01, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $01, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $01, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $01, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $01, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $01, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $01, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $01, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $01, $01, $01,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $01, $01, $01,
Map1End:

Map2:
    db $01, $08, $01, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $01, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $01, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $01, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $01, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $01, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $01, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $01, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $01, $01, $01,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
    db $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08, $08,
 Map2End:


Player:
    dw `00000000
    dw `30300303
    dw `03000030
    dw `00333300
    dw `03133130
    dw `33133133
    dw `33333333
    dw `30000003
Player2:
    dw `00000000
    dw `03000030
    dw `03000030
    dw `00333300
    dw `03233230
    dw `33233233
    dw `33333333
    dw `03000030
PlayerEnd:
    
SECTION "Counters", HRAM
wFrameCounter: db
wRandomSeed: db
wLevel: dw

SECTION "Input Variables", WRAM0
wCurKeys: db
wNewKeys: db
