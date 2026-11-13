int g(int a, int b) {
  float x = 3.7;
  float y = 4.;
  while(a != b) {
    if (a > b) {
      a -= b;
    }
    else {
      b -= a;
    }
  }

  return a;
}
