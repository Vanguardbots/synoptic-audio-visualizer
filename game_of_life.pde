/**
 * Audio-Reactive Life Pixels (File chooser + Grid version)
 * - Game of Life–inspired cellular automaton
 * - Audio-reactive via FFT (Minim)
 * - Renders square "pixels" on a black field with thin white grid lines
 *
 * On startup, you’ll pick a local audio file (mp3/wav).
 *
 * Controls:
 *   S : start/stop simulation
 *   P : play/pause audio
 *   R : randomize seed
 *   C : clear grid
 *   N : step once (when paused)
 *   1 / 2 : audio influence - / +
 *   G : toggle grid lines
 *   H : toggle HUD
 *
 * Tip: Adjust cellSize for coarser/finer pixels.
 */

import ddf.minim.*;
import ddf.minim.analysis.*;
import java.io.File;

Minim minim;
AudioPlayer player;
FFT fft;

// ---------- Grid & cells ----------
int cellSize = 10;           // pixel size; change for resolution
int cols, rows;
boolean[][] grid, next;
boolean running = true;

// Life rule (base reference)
boolean[] birth  = new boolean[9];
boolean[] survive = new boolean[9];

// ---------- Rendering ----------
PGraphics gridLayer;         // pre-rendered thin white grid
boolean showGrid = true;
boolean showHUD  = true;

// ---------- Audio ----------
float audioInfluence = 0.9f; // 0..1 how much sound modulates rules
float bassEnergy, midEnergy, trebleEnergy, rms;
float t = 0;

void settings() {
  size(1200, 800, P2D);
  smooth(4);
}

void setup() {
  // Choose audio on launch
  selectInput("Select an audio file to play:", "fileSelected");

  initGrid();
  setClassicLifeRule();
  randomizeGrid(0.15f);
  makeGridLayer();
  background(0);
}

void initGrid() {
  cols = ceil(width / (float)cellSize);
  rows = ceil(height / (float)cellSize);
  grid = new boolean[cols][rows];
  next = new boolean[cols][rows];
}

void makeGridLayer() {
  gridLayer = createGraphics(width, height, P2D);
  gridLayer.beginDraw();
  gridLayer.background(0, 0); // transparent
  gridLayer.stroke(255, 40);  // thin, subtle white
  gridLayer.strokeWeight(1);

  // vertical lines
  for (int x=0; x<=cols; x++) {
    float px = x * cellSize + 0.5f; // hairline alignment
    gridLayer.line(px, 0, px, height);
  }
  // horizontal lines
  for (int y=0; y<=rows; y++) {
    float py = y * cellSize + 0.5f;
    gridLayer.line(0, py, width, py);
  }
  gridLayer.endDraw();
}

// ------- File chooser callback -------
void fileSelected(File selection) {
  if (selection == null) {
    println("No file selected. Exiting.");
    exit();
    return;
  }
  println("Loading: " + selection.getAbsolutePath());
  minim = new Minim(this);
  try {
    player = minim.loadFile(selection.getAbsolutePath(), 2048);
    if (player == null) {
      println("Minim failed to load file. Exiting.");
      exit();
      return;
    }
    fft = new FFT(player.bufferSize(), player.sampleRate());
    fft.logAverages(22, 3);
    player.loop();
  } catch (Exception e) {
    println("Error loading file: " + e);
    exit();
  }
}

// ---------------- Main loop ----------------
void draw() {
  background(0);
  t += 1.0/60.0;

  analyzeAudio();

  if (running) updateCells();

  drawCellsAsPixels();
  if (showGrid) image(gridLayer, 0, 0);

  if (showHUD) drawHUD();
}

// --------------- Life simulation ---------------
void setClassicLifeRule() {
  for (int i=0; i<9; i++) { birth[i] = false; survive[i] = false; }
  birth[3] = true;
  survive[2] = true;
  survive[3] = true;
}

void randomizeGrid(float density) {
  for (int x=0; x<cols; x++) {
    for (int y=0; y<rows; y++) {
      grid[x][y] = (random(1) < density);
    }
  }
}

void clearGrid() {
  for (int x=0; x<cols; x++) for (int y=0; y<rows; y++) grid[x][y] = false;
}

int countNeighbors(int x, int y) {
  int n = 0;
  for (int dx=-1; dx<=1; dx++) {
    for (int dy=-1; dy<=1; dy++) {
      if (dx==0 && dy==0) continue;
      int cx = (x + dx + cols) % cols;  // wrap
      int cy = (y + dy + rows) % rows;
      if (grid[cx][cy]) n++;
    }
  }
  return n;
}

void updateCells() {
  // Audio-reactive modulation
  float bassBias    = constrain(map(bassEnergy,   0, 0.25, 0, 0.60), 0, 0.60) * audioInfluence;
  float midBias     = constrain(map(midEnergy,    0, 0.20, 0, 0.45), 0, 0.45) * audioInfluence;
  float trebleSpark = constrain(map(trebleEnergy, 0, 0.12, 0, 0.20), 0, 0.20) * audioInfluence;

  for (int x=0; x<cols; x++) {
    for (int y=0; y<rows; y++) {
      int n = countNeighbors(x, y);
      boolean alive = grid[x][y];
      boolean nextAlive;

      if (!alive) {
        if (n == 3) nextAlive = true;
        else if (n == 2 && random(1) < 0.15*bassBias) nextAlive = true;
        else if (random(1) < trebleSpark*0.005) nextAlive = true;
        else nextAlive = false;
      } else {
        if (n == 2 || n == 3) nextAlive = true;
        else if (n == 4 && random(1) < 0.25*midBias) nextAlive = true;
        else nextAlive = false;
      }
      next[x][y] = nextAlive;
    }
  }

  // swap
  boolean[][] tmp = grid; grid = next; next = tmp;

  // occasional reseed when very quiet to avoid stagnation
  if (running && frameCount % 90 == 0) {
    float quiet = 1.0 - constrain(rms*3.0, 0, 1);
    if (random(1) < 0.4*quiet) sprinkleLife(0.02 + 0.10*quiet);
  }
}

void sprinkleLife(float density) {
  for (int i=0; i<int(cols*rows*density); i++) {
    int x = int(random(cols));
    int y = int(random(rows));
    grid[x][y] = true;
  }
}

// --------------- Rendering: pixels + grid ---------------
void drawCellsAsPixels() {
  noStroke();
  // Slight brightness reacts to RMS to give subtle “throb”
  float bright = 220 + 35 * constrain(rms*4.0, 0, 1); // 220..255
  fill(bright);

  // Draw only alive cells as filled squares
  for (int x=0; x<cols; x++) {
    for (int y=0; y<rows; y++) {
      if (!grid[x][y]) continue;
      rect(x*cellSize, y*cellSize, cellSize, cellSize);
    }
  }
}

// ---------------- Audio ----------------
void analyzeAudio() {
  if (player == null) {
    bassEnergy = midEnergy = trebleEnergy = rms = 0;
    return;
  }
  rms = max(0, player.mix.level());
  fft.forward(player.mix);

  int bassEnd   = max(1, int(fft.specSize() * 0.05));     // ~0-5%
  int midEnd    = max(bassEnd+1, int(fft.specSize() * 0.25)); // ~5-25%
  int trebleEnd = fft.specSize();

  bassEnergy   = bandEnergy(0, bassEnd)       * 1.4;
  midEnergy    = bandEnergy(bassEnd, midEnd)  * 1.1;
  trebleEnergy = bandEnergy(midEnd, trebleEnd)* 1.0;
}

float bandEnergy(int start, int end) {
  float sum = 0;
  int count = max(1, end - start);
  for (int i=start; i<end; i++) sum += fft.getBand(i);
  return sum / count;
}

// ---------------- UI ----------------
void keyPressed() {
  if (key=='s' || key=='S') running = !running;
  else if (key=='p' || key=='P') {
    if (player != null) {
      if (player.isPlaying()) player.pause(); else player.play();
    }
  }
  else if (key=='r' || key=='R') randomizeGrid(0.18f);
  else if (key=='c' || key=='C') clearGrid();
  else if (key=='n' || key=='N') if (!running) updateCells();
  else if (key=='g' || key=='G') showGrid = !showGrid;
  else if (key=='h' || key=='H') showHUD  = !showHUD;
}

void drawHUD() {
  fill(255);
  textFont(createFont("Menlo", 12));
  int y = 18;
  String[] lines = new String[] {
    "Audio-Reactive Life Pixels",
    "S: sim " + (running ? "PAUSE" : "RUN") + "   P: audio " + ((player!=null && player.isPlaying())?"PAUSE":"PLAY"),
    "R: randomize   C: clear   N: step (paused)",
    "G: toggle grid   H: toggle HUD",
    "cellSize: " + cellSize + "  grid: " + cols + " x " + rows,
    "audio influence (fixed): " + nf(audioInfluence,1,2),
    "bass: " + nf(bassEnergy,1,3) + "  mid: " + nf(midEnergy,1,3) + "  treble: " + nf(trebleEnergy,1,3) + "  rms: " + nf(rms,1,3)
  };
  for (String s : lines) { text(s, 12, y); y += 16; }
}

// ---------------- Cleanup ----------------
void stop() {
  try {
    if (player != null) player.close();
    if (minim != null) minim.stop();
  } catch (Exception e) {}
  super.stop();
}
