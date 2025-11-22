/**
 * Synoptic Audio Visualizer — PRO (Processing + Sound + ControlP5)
 * Features:
 *  - Isobars + filled isobands ("precip" zones)
 *  - Gradient-based front detection with markers (warm/cold/occluded)
 *  - Wind particles + meteorological wind barbs
 *  - UI controls: isobar spacing, noise scale, wind count, color theme
 *  - UI toggles: [U] hide/show ControlP5, [H] hide/show HUD
 *  - Cinema Mode: [C] hides cursor/UI/HUD, boosts line weights/alpha for projection
 *
 * Keys:
 *   [SPACE] play/pause   [S] save frame
 *   [U] toggle ControlP5 UI   [H] toggle HUD overlays
 *   [C] toggle Cinema Mode
 */

import processing.sound.*;
import controlP5.*;
import java.io.File;

SoundFile file;
FFT fft;
Amplitude amp;

final int FFT_BINS = 512;
float[] spectrum = new float[FFT_BINS];

boolean playing = true;

// Grid / field
int cols = 140, rows = 90;        // increase for finer contours (costs CPU)
float[][] field;                  // scalar "pressure"
float[][] gradMag;                // |∇field|
PVector[][] grad;                 // gradient vectors (for fronts/barbs)
float noiseScale = 0.015f;
float time = 0;
float tSpeed = 0.4f;

// Isolines / isobands
float isoBase = 0;
float isoStep = 0.16f;
int   isoCount = 9;

// Wind particles
int windCount = 420;
PVector[] windPos;
PVector[] windVel;

// Barbs (grid)
int barbCols = 20, barbRows = 12; // coarse barb grid

// UI
ControlP5 cp5;
float ui_isoStep    = isoStep;
float ui_noiseScale = noiseScale;
int   ui_windCount  = windCount;
String ui_theme     = "Classic";  // [Classic, Night, Thermal]
String[] THEMES = {"Classic","Night","Thermal"};

// UI visibility toggles
boolean showUI  = true;   // ControlP5 panel visibility
boolean showHUD = true;   // text overlays (title + meters)

// Cinema mode (projection-ready)
boolean cinemaMode = false;
boolean prevShowUI = true, prevShowHUD = true; // restore after cinema mode

// Style
PFont pf;
int bgCol;
int lineCold, lineWarm, lineOcc, isoColor;
int washA = 40;     // base alpha for background wash

// Style boosts when cinemaMode is on
float isoStrokeBase = 1.4;
float barbWeightBase = 1.6;

void settings() {
  size(1400, 900, P2D);
  smooth(4);
}

void setup() {
  surface.setTitle("Synoptic Audio Visualizer — PRO");
  pf = createFont("SansSerif.bold", 18);
  textFont(pf);

  // Audio
  amp = new Amplitude(this);
  fft = new FFT(this, FFT_BINS);
  selectInput("Choose an audio file:", "fileSelected");

  field   = new float[cols][rows];
  gradMag = new float[cols][rows];
  grad    = new PVector[cols][rows];
  for (int x=0;x<cols;x++) for (int y=0;y<rows;y++) grad[x][y]=new PVector();

  // Wind
  windPos = new PVector[windCount];
  windVel = new PVector[windCount];
  for (int i = 0; i < windCount; i++) {
    windPos[i] = new PVector(random(width), random(height));
    windVel[i] = new PVector();
  }

  colorMode(HSB, 360, 100, 100, 100);
  applyTheme("Classic");

  // ----- ControlP5 UI -----
  cp5 = new ControlP5(this);
  int panelX = 14, panelY = 14, w = 220;

  cp5.addSlider("ui_isoStep")
     .setPosition(panelX, panelY+30)
     .setWidth(w).setRange(0.06f, 0.45f).setValue(isoStep)
     .setLabel("Isobar Spacing");

  cp5.addSlider("ui_noiseScale")
     .setPosition(panelX, panelY+70)
     .setWidth(w).setRange(0.006f, 0.04f).setValue(noiseScale)
     .setLabel("Noise Scale");

  cp5.addSlider("ui_windCount")
     .setPosition(panelX, panelY+110)
     .setWidth(w).setRange(80, 1200).setValue(windCount)
     .setLabel("Wind Particle Count");

  cp5.addScrollableList("ui_theme")
     .setPosition(panelX, panelY+160)
     .setSize(w, 90)
     .setBarHeight(20)
     .setItemHeight(20)
     .addItems(java.util.Arrays.asList(THEMES))
     .setOpen(false)
     .setLabel("Theme");
  cp5.getController("ui_theme").getCaptionLabel().set("Theme");

  // Ensure UI starts visible
  cp5.show();

  strokeCap(ROUND);
}

void fileSelected(File selection) {
  if (selection == null) return;
  if (file != null) file.stop();
  file = new SoundFile(this, selection.getAbsolutePath());
  file.loop();
  amp.input(file);
  fft.input(file);
}

void draw() {
  background(bgCol);

  if (file == null) {
    drawHint("Load an audio file to begin…");
    return;
  }

  // Sync params from UI (cheap every frame)
  if (abs(ui_isoStep - isoStep) > 1e-6) isoStep = ui_isoStep;
  if (abs(ui_noiseScale - noiseScale) > 1e-6) noiseScale = ui_noiseScale;
  if (ui_windCount != windCount) resizeWind(ui_windCount);

  // Audio features
  fft.analyze(spectrum);
  float level = amp.analyze();
  float bass  = bandEnergy(spectrum, 20, 140);
  float mids  = bandEnergy(spectrum, 200, 2000);
  float highs = bandEnergy(spectrum, 3000, 10000);

  float energy = constrain(map(mids + 0.7*bass + 0.4*highs, 0, 600, 0.2, 2.6), 0.1, 3.0);
  time += (tSpeed * (0.6 + 0.8*energy)) * 0.01;

  // Field & gradients
  computeField(level, bass, mids, highs);
  computeGradients();

  // Shaded pressure wash (soft background)
  drawShadedPressure();

  // Isobands (filled precip zones)
  drawIsobands();

  // Isolines (thicker in cinema mode)
  strokeWeight(isoStrokeW());
  stroke(isoColor, cinemaMode ? 80 : 60);
  for (int i = -isoCount; i <= isoCount; i++) {
    float iso = isoBase + i * isoStep;
    marchingSquares(iso, false); // outlines only
  }

  // Front detection & markers
  drawFronts();

  // Pressure centers (H/L)
  drawPressureCenters();

  // Wind layer (higher alpha in cinema mode)
  drawWindParticles(level, energy);

  // Wind barbs on a coarse grid (thicker in cinema mode)
  drawWindBarbs();

  // HUD (toggle + suppressed in cinema mode)
  if (showHUD && !cinemaMode) {
    drawHUD(level, bass, mids, highs);
  }
}

// ---------- UI events ----------
public void ui_theme(int idx) { /* unused - list returns Map on click */ }
public void controlEvent(ControlEvent e) {
  if (e.isFrom("ui_theme") && e.getController() instanceof ScrollableList) {
    String sel = e.getController().getStringValue();
    if (sel != null && sel.length() > 0) applyTheme(sel);
  }
}

void applyTheme(String name) {
  ui_theme = name;
  if ("Night".equals(name)) {
    bgCol = color(220, 20, 10);
    isoColor = color(210, 8, 95);
    lineCold = color(215, 70, 95);
    lineWarm = color(0,   75, 95);
    lineOcc  = color(285, 60, 90);
    washA = 42;
  } else if ("Thermal".equals(name)) {
    bgCol = color(250, 15, 12);
    isoColor = color(260, 40, 95);
    lineCold = color(200, 80, 90);
    lineWarm = color(25,  90, 95);
    lineOcc  = color(300, 70, 90);
    washA = 46;
  } else { // Classic
    bgCol = color(210, 10, 10);
    isoColor = color(220, 20, 95);
    lineCold = color(210, 80, 95);
    lineWarm = color(0,   80, 95);
    lineOcc  = color(290, 60, 90);
    washA = 40;
  }
}

// ---------- AUDIO ----------
float bandEnergy(float[] spec, float loHz, float hiHz) {
  float nyquist = 22050.0;
  int n = spec.length;
  int a = max(0, floor(map(loHz, 0, nyquist, 0, n - 1)));
  int b = min(n - 1, ceil (map(hiHz, 0, nyquist, 0, n - 1)));
  float sum = 0;
  for (int i = a; i <= b; i++) sum += spec[i];
  return sum;
}

// ---------- FIELD & GRADIENTS ----------
void computeField(float level, float bass, float mids, float highs) {
  float bassPush  = map(bass,  0,  300, 0.0, 0.6);
  float midWobble = map(mids,  0, 1200, 0.0, 0.35);
  float hiRipple  = map(highs, 0,  600, 0.0, 0.25);

  for (int x = 0; x < cols; x++) {
    for (int y = 0; y < rows; y++) {
      float nx = x * noiseScale;
      float ny = y * noiseScale;
      float base   = noise(nx + time*0.5, ny) * 2 - 1;
      float octave = (noise(nx*2.0 + 100, ny*2.0 + 50 + time*0.9) * 2 - 1) * 0.5;
      float ripple = sin((nx*7.0 + ny*6.0) + time*10.0) * hiRipple;
      field[x][y] = base + octave + ripple + bassPush - midWobble*0.5;
    }
  }
}

void computeGradients() {
  float sx = 1.0/(cols-1), sy = 1.0/(rows-1); // normalized spacing (visual)
  for (int x = 1; x < cols-1; x++) {
    for (int y = 1; y < rows-1; y++) {
      float dx = (field[x+1][y] - field[x-1][y]) * 0.5f / sx;
      float dy = (field[x][y+1] - field[x][y-1]) * 0.5f / sy;
      grad[x][y].set(dx, dy);
      gradMag[x][y] = sqrt(dx*dx + dy*dy);
    }
  }
  // edges: copy from neighbors
  for (int x=0; x<cols; x++) { grad[x][0].set(grad[x][1]); grad[x][rows-1].set(grad[x][rows-2]); }
  for (int y=0; y<rows; y++) { grad[0][y].set(grad[1][y]); grad[cols-1][y].set(grad[cols-2][y]); }
  for (int x=0; x<cols; x++) { gradMag[x][0]=gradMag[x][1]; gradMag[x][rows-1]=gradMag[x][rows-2]; }
  for (int y=0; y<rows; y++) { gradMag[0][y]=gradMag[1][y]; gradMag[cols-1][y]=gradMag[cols-2][y]; }
}

// ---------- ISOBANDS (filled) ----------
void drawIsobands() {
  // Per-cell fill heuristic for speed; visually reads like precip blobs
  noStroke();
  int localWashA = cinemaMode ? washA + 10 : washA; // slight boost in cinema
  for (int i = -isoCount; i < isoCount; i++) {
    float lo = isoBase + i * isoStep;
    float hi = lo + isoStep;

    int c = bandColor(i);
    fill(c, 35);  // translucent fill per band

    for (int x = 0; x < cols-1; x++) {
      for (int y = 0; y < rows-1; y++) {
        boolean in =
          inBand(field[x][y], lo, hi) ||
          inBand(field[x+1][y], lo, hi) ||
          inBand(field[x][y+1], lo, hi) ||
          inBand(field[x+1][y+1], lo, hi);
        if (in) {
          float x0 = map(x,   0, cols-1, 0, width);
          float y0 = map(y,   0, rows-1, 0, height);
          float x1 = map(x+1, 0, cols-1, 0, width);
          float y1 = map(y+1, 0, rows-1, 0, height);
          // use local wash alpha (subtle; the rect fill uses 'fill(c, 35)' already)
          rect(x0, y0, x1-x0+1, y1-y0+1);
        }
      }
    }
  }
}

boolean inBand(float v, float lo, float hi) { return (v >= lo && v <= hi); }

int bandColor(int bandIndex) {
  // cooler for lows, warmer for highs around isoBase
  if (bandIndex < 0) {
    float t = map(bandIndex, -isoCount, -1, 0, 1);
    return color(210, 40 + 40*t, 70 + 20*t); // blues
  } else if (bandIndex > 0) {
    float t = map(bandIndex, 1, isoCount, 0, 1);
    return color(15,  55 + 30*t, 75 + 20*t); // oranges/reds
  } else {
    return color(200, 20, 70);
  }
}

// ---------- MARCHING SQUARES (isoline only) ----------
void marchingSquares(float iso, boolean fillPoly) {
  // Only outlines used here; filled handled by drawIsobands().
  noFill();
  for (int x = 0; x < cols-1; x++) {
    for (int y = 0; y < rows-1; y++) {
      float a = field[x][y]     - iso;
      float b = field[x+1][y]   - iso;
      float c = field[x+1][y+1] - iso;
      float d = field[x][y+1]   - iso;
      int idx = (a > 0 ? 8 : 0) | (b > 0 ? 4 : 0) | (c > 0 ? 2 : 0) | (d > 1 ? 1 : 0);
      // (typo safeguard) correct idx calc:
      idx = (a > 0 ? 8 : 0) | (b > 0 ? 4 : 0) | (c > 0 ? 2 : 0) | (d > 0 ? 1 : 0);

      PVector pA = lerpEdge(x, y, x+1, y, a, b);
      PVector pB = lerpEdge(x+1, y, x+1, y+1, b, c);
      PVector pC = lerpEdge(x, y+1, x+1, y+1, d, c);
      PVector pD = lerpEdge(x, y, x, y+1, a, d);

      switch(idx) {
        case 0: case 15: break;
        case 1: case 14: lineP(pD, pC); break;
        case 2: case 13: lineP(pB, pC); break;
        case 3: case 12: lineP(pB, pD); break;
        case 4: case 11: lineP(pA, pB); break;
        case 5:          lineP(pA, pD); lineP(pB, pC); break;
        case 6: case 9:  lineP(pA, pC); break;
        case 7: case 8:  lineP(pA, pD); break;
        case 10:         lineP(pA, pB); lineP(pC, pD); break;
      }
    }
  }
}

PVector lerpEdge(int x1, int y1, int x2, int y2, float v1, float v2) {
  float t = 0.5;
  float denom = (v1 - v2);
  if (abs(denom) > 1e-6) t = v1 / (v1 - v2);
  float sx = map(x1 + t*(x2 - x1), 0, cols-1, 0, width);
  float sy = map(y1 + t*(y2 - y1), 0, rows-1, 0, height);
  return new PVector(sx, sy);
}

void lineP(PVector a, PVector b) { if (a == null || b == null) return; line(a.x, a.y, b.x, b.y); }

// ---------- FRONTS ----------
void drawFronts() {
  // Detect high gradient bands; place markers along gradient direction.
  int skip = 4; // keep this constant; visuals get too dense otherwise
  for (int x = 1; x < cols-1; x += skip) {
    for (int y = 1; y < rows-1; y += skip) {
      float g = gradMag[x][y];
      if (g < 0.35f) continue;

      // Map grid to screen
      float sx = map(x, 0, cols-1, 0, width);
      float sy = map(y, 0, rows-1, 0, height);

      // Orientation from gradient (front typically perpendicular to isobars)
      PVector v = grad[x][y];
      float ang = atan2(v.y, v.x);

      if (field[x][y] > isoBase + isoStep*0.5f) {
        drawWarmFrontMarker(sx, sy, ang);
      } else if (field[x][y] < isoBase - isoStep*0.5f) {
        drawColdFrontMarker(sx, sy, ang);
      } else {
        drawOccludedFrontMarker(sx, sy, ang);
      }
    }
  }
}

void drawWarmFrontMarker(float x, float y, float angle) {
  pushMatrix();
  translate(x, y);
  rotate(angle);
  stroke(lineWarm, cinemaMode ? 95 : 85);
  fill(lineWarm, cinemaMode ? 95 : 85);
  float r = cinemaMode ? 11 : 9;
  arc(0, 0, r*2, r*2, -HALF_PI*0.8, HALF_PI*0.8, PIE);
  popMatrix();
}

void drawColdFrontMarker(float x, float y, float angle) {
  pushMatrix();
  translate(x, y);
  rotate(angle);
  stroke(lineCold, cinemaMode ? 95 : 85);
  fill(lineCold, cinemaMode ? 95 : 85);
  float s = cinemaMode ? 11 : 9;
  triangle(0, 0, -s, -s*0.7, -s, s*0.7);
  popMatrix();
}

void drawOccludedFrontMarker(float x, float y, float angle) {
  pushMatrix();
  translate(x, y);
  rotate(angle);
  stroke(lineOcc, cinemaMode ? 95 : 85);
  fill(lineOcc, cinemaMode ? 95 : 85);
  float s = cinemaMode ? 10 : 8, r = cinemaMode ? 10 : 8;
  arc(0, 0, r*2, r*2, -HALF_PI*0.8, HALF_PI*0.8, PIE);
  triangle(12, 0, 12 - s, -s*0.7, 12 - s, s*0.7);
  popMatrix();
}

// ---------- WIND PARTICLES ----------
void drawWindParticles(float level, float energy) {
  stroke(0, 0, 100, cinemaMode ? 95 : 65);
  strokeWeight(cinemaMode ? 1.6 : 1.2);
  for (int i = 0; i < windCount; i++) {
    PVector p = windPos[i];
    PVector v = windVel[i];

    float nx = (p.x/width) * 1.8f + time*0.6f;
    float ny = (p.y/height) * 1.8f + time*0.6f;

    float e = curl(nx, ny);
    float ang = e * TWO_PI;
    v.x = cos(ang);
    v.y = sin(ang);

    float speed = map(energy, 0.1, 3.0, 0.8, 4.0);
    PVector step = PVector.mult(v, speed);
    PVector prev = p.copy();
    p.add(step);

    // jitter on beat
    p.x += (noise(i*0.1f, time*10) - 0.5f) * 2.0f * (0.4 + 1.2f*level);
    p.y += (noise(i*0.13f, time*9) - 0.5f) * 2.0f * (0.4 + 1.2f*level);

    // wrap
    if (p.x < 0) p.x += width;
    if (p.y < 0) p.y += height;
    if (p.x >= width) p.x -= width;
    if (p.y >= height) p.y -= height;

    line(prev.x, prev.y, p.x, p.y);
    if (i % 8 == 0) {
      pushMatrix();
      translate(p.x, p.y);
      float a = atan2(step.y, step.x);
      rotate(a);
      line(0, 0, -6, 2);
      line(0, 0, -6, -2);
      popMatrix();
    }
  }
}

// ---------- WIND BARBS ----------
void drawWindBarbs() {
  float gw = width / (float)barbCols;
  float gh = height / (float)barbRows;
  strokeWeight(barbWeight());
  for (int i = 0; i < barbCols; i++) {
    for (int j = 0; j < barbRows; j++) {
      float x = (i + 0.5f) * gw;
      float y = (j + 0.5f) * gh;

      float nx = (x/width) * 1.8f + time*0.6f;
      float ny = (y/height) * 1.8f + time*0.6f;

      float e = curl(nx, ny);
      float ang = e * TWO_PI;

      // pseudo speed from local gradient magnitude
      int gx = int(map(i, 0, barbCols-1, 1, cols-2));
      int gy = int(map(j, 0, barbRows-1, 1, rows-2));
      float speed = constrain(gradMag[gx][gy] * 0.12f, 0, 1.8f);

      drawBarb(x, y, ang, speed);
    }
  }
}

void drawBarb(float x, float y, float angle, float speed) {
  int knots = int(map(speed, 0, 2, 0, 40));
  int fifties = knots / 50; knots %= 50;
  int tens    = knots / 10; knots %= 10;
  int fives   = knots / 5;

  pushMatrix();
  translate(x, y);
  rotate(angle);

  stroke(0, 0, 100, cinemaMode ? 95 : 85);
  // staff
  line(0, 0, 0, -(cinemaMode ? 34 : 28));

  float pos = -4;
  float step = cinemaMode ? 7 : 6;

  // pennants (50s)
  for (int i = 0; i < fifties; i++) {
    fill(0, 0, 100, cinemaMode ? 95 : 85);
    beginShape();
    vertex(0, pos);
    vertex(0, pos - step*2);
    vertex(10, pos - step);
    endShape(CLOSE);
    pos -= step*2.4;
  }
  // full barbs (10s)
  for (int i = 0; i < tens; i++) {
    line(0, pos, cinemaMode ? 12 : 10, pos - (cinemaMode ? 5 : 4));
    pos -= step;
  }
  // half barb (5)
  if (fives > 0) {
    line(0, pos, cinemaMode ? 7 : 6, pos - (cinemaMode ? 3 : 2.4));
  }

  popMatrix();
}

// ---------- FLOW UTILS ----------
float curl(float x, float y) {
  float eps = 0.001;
  float n1 = noise(x, y+eps);
  float n2 = noise(x, y-eps);
  float n3 = noise(x+eps, y);
  float n4 = noise(x-eps, y);
  float dx = (n1 - n2);
  float dy = (n3 - n4);
  return (dx - dy);
}

// ---------- SHADING ----------
void drawShadedPressure() {
  noStroke();
  int localWashA = cinemaMode ? washA + 10 : washA;
  for (int y = 0; y < rows-1; y++) {
    beginShape(QUAD_STRIP);
    for (int x = 0; x < cols; x++) {
      float v1 = field[x][y];
      float v2 = field[x][y+1];
      int c1 = color(map(v1, -1, 1, 200, 230), 20, map(v1, -1, 1, 35, 65), localWashA);
      int c2 = color(map(v2, -1, 1, 200, 230), 20, map(v2, -1, 1, 35, 65), localWashA);
      fill(c1); vertex(map(x,0,cols-1,0,width),   map(y,0,rows-1,0,height));
      fill(c2); vertex(map(x,0,cols-1,0,width),   map(y+1,0,rows-1,0,height));
    }
    endShape();
  }
}

// ---------- H/L centers ----------
void drawPressureCenters() {
  textAlign(CENTER, CENTER);
  textSize(cinemaMode ? 20 : 18);
  fill(0, 0, 100, cinemaMode ? 100 : 100);
  noStroke();
  for (int x = 1; x < cols-1; x++) {
    for (int y = 1; y < rows-1; y++) {
      float v = field[x][y];
      boolean isMax = v > field[x-1][y] && v > field[x+1][y] && v > field[x][y-1] && v > field[x][y+1];
      boolean isMin = v < field[x-1][y] && v < field[x+1][y] && v < field[x][y-1] && v < field[x][y+1];
      if (isMax && random(1) < 0.0016) {
        text("H", map(x,0,cols-1,0,width), map(y,0,rows-1,0,height));
      } else if (isMin && random(1) < 0.0016) {
        text("L", map(x,0,cols-1,0,width), map(y,0,rows-1,0,height));
      }
    }
  }
}

// ---------- HUD ----------
void drawHUD(float level, float bass, float mids, float highs) {
  fill(0, 0, 100, 92);
  noStroke();
  rect(12, 12, 560, 22, 8);
  fill(0, 0, 0, 95);
  textAlign(LEFT, CENTER);
  text("Synoptic Visualizer — PRO   [SPACE] play/pause   [U] UI   [H] HUD   [C] Cinema   [S] save", 20, 23);

  // quick readings
  fill(0, 0, 100, 80);
  rect(12, height-72, 380, 56, 10);
  fill(0, 0, 0, 95);
  textAlign(LEFT, TOP);
  text(String.format("Level: %.3f\nBass:  %.1f   Mids: %.1f   Highs: %.1f", level, bass, mids, highs), 22, height-66);
}

void drawHint(String s) {
  fill(0, 0, 100, 100);
  textAlign(CENTER, CENTER);
  text(s, width/2, height/2);
}

// ---------- WIND RESIZE ----------
void resizeWind(int newCount) {
  newCount = max(20, newCount);
  PVector[] nPos = new PVector[newCount];
  PVector[] nVel = new PVector[newCount];
  for (int i = 0; i < newCount; i++) {
    if (i < windCount) {
      nPos[i] = windPos[i];
      nVel[i] = windVel[i];
    } else {
      nPos[i] = new PVector(random(width), random(height));
      nVel[i] = new PVector();
    }
  }
  windPos = nPos;
  windVel = nVel;
  windCount = newCount;
}

// ---------- INPUT ----------
void keyPressed() {
  if (key == ' ') {
    playing = !playing;
    if (playing && file != null) file.loop();
    else if (file != null) file.pause();
  } else if (key == 's' || key == 'S') {
    saveFrame("synoptic-pro-####.png");
  } else if (key == 'u' || key == 'U') {
    // Toggle ControlP5 UI visibility (disabled while in cinema mode)
    if (!cinemaMode) {
      showUI = !showUI;
      if (showUI) cp5.show();
      else cp5.hide();
    }
  } else if (key == 'h' || key == 'H') {
    // Toggle HUD overlays (disabled while in cinema mode)
    if (!cinemaMode) {
      showHUD = !showHUD;
    }
  } else if (key == 'c' || key == 'C') {
    toggleCinemaMode();
  }
}

// ---------- CINEMA MODE ----------
void toggleCinemaMode() {
  cinemaMode = !cinemaMode;
  if (cinemaMode) {
    // remember current states
    prevShowUI = showUI;
    prevShowHUD = showHUD;
    // hide UI/HUD, hide cursor
    showUI = false;
    showHUD = false;
    cp5.hide();
    noCursor();
  } else {
    // restore UI/HUD & cursor
    showUI = prevShowUI;
    showHUD = prevShowHUD;
    if (showUI) cp5.show(); else cp5.hide();
    cursor(ARROW);
  }
}

// ---------- STYLE HELPERS ----------
float isoStrokeW() {
  return isoStrokeBase * (cinemaMode ? 1.6 : 1.0);
}
float barbWeight() {
  return barbWeightBase * (cinemaMode ? 1.4 : 1.0);
}
