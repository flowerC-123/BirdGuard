#ifndef __FILE_UTILS_H__
#define __FILE_UTILS_H__

int read_data_from_file(const char *path, char **out_data);

int write_data_to_file(const char *path, const char *data, unsigned int size);

char **read_lines_from_file(const char *path, int *line_count);

void free_lines(char **lines, int line_count);

#endif